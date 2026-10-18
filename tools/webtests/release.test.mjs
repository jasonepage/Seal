// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  release.test.mjs
//
//  Proves site/open/js/release.js judges an estate exactly as the phone
//  does. Every case here is ported from a Swift self-test, with the same
//  inputs and the same expected outcomes, and each check name starts with
//  the Swift suite it came from:
//
//    Seal/SelfTest/ReleaseMachineTests.swift   (release.*)
//    Seal/SelfTest/EstateLogTests.swift        (estatelog.feed, estatelog.releaseAdmission)
//    Seal/SelfTest/FirstSeenTests.swift        (firstseen.backdatedClaimStillWarns)
//    Seal/SelfTest/DepartureTests.swift        (departure.*)
//
//  Run from the repo root:  node tools/webtests/release.test.mjs
//
//  The Swift tests build signed events. Nothing here checks a signature
//  (that is estatelog.js and its own tests), so events are plain objects
//  carrying the fields release.js reads, with bodies holding the same
//  values the Swift encodes. Where the Swift hands the feed a FirstSeen
//  table, the `Phone` helper below records the same first sightings and
//  turns them into the `times` map, by FirstSeen.timeOf's own rule.
//
//  A few thin Swift helpers that release.js does not carry (nextTransition,
//  ownerCanCancel, custodianCanClaim, custodianCanAuthorize,
//  claimantCanRelease, DepartureRules.earliestClaim and earliestOpening)
//  are written out below, line for line from ReleaseMachine.swift and
//  DepartureRules.swift, on top of the ported state, timeline, voidReason
//  and validAuthorizations. That way their checks still test the port.

import { isDeepStrictEqual, inspect } from "node:util";
import {
  effectiveTime, policyWith, snapshot, voidReason, timeline, validAuthorizations,
  state, releaseEarned, silentDays, openingAllowed,
  custodianCanClaim, custodianCanAuthorize, claimantCanRelease,
} from "../../site/open/js/release.js";

// ---------------------------------------------------------------- harness (SelfTest.Context)

let checks = 0;
const failures = [];
function check(cond, name, detail = "") {
  checks += 1;
  if (!cond) failures.push({ name, detail });
  return cond;
}
const show = (v) => inspect(v, { depth: 6, breakLength: Infinity });
function equal(actual, expected, name) {
  check(isDeepStrictEqual(actual, expected), name, `expected ${show(expected)}, got ${show(actual)}`);
}
/** Prefixes each check name with its Swift suite name. */
function suite(name) {
  return {
    check: (cond, n, d) => check(cond, `${name}: ${n}`, d),
    equal: (a, e, n) => equal(a, e, `${name}: ${n}`),
  };
}

// ---------------------------------------------------------------- shared values

const DAY = 86_400;
const t0 = 1_800_000_000;
const clone = (v) => structuredClone(v);

// Swift's ReleasePolicy as JSONEncoder writes it into a body, and as
// schema.js decodes it back (custodyConfirmMonths included).
const bodyPolicy = (threshold, change = {}) => ({ ...policyWith(threshold), custodyConfirmMonths: 12, ...change });

// ---------------------------------------------------------------- thin Swift helpers not in release.js

const silenceAnchor = (s) => s.lastHeartbeatAt ?? s.estateCreatedAt;
const claimIsLive = (st) => ["warning", "grace", "claimOpen", "authorized", "objected"].includes(st);

/** ReleaseMachine.nextTransition */
function nextTransition(s, now) {
  let natural;
  switch (state(s, now)) {
    case "active":
    case "cancelled":
      natural = silenceAnchor(s) + s.policy.silenceDays * DAY;
      break;
    case "warning":
      natural = timeline(s, now)?.warningEndsAt ?? null;
      break;
    case "grace":
      natural = timeline(s, now)?.claimOpensAt ?? null;
      break;
    case "released":
      return null;
    default:
      natural = null;
  }
  if (s.releasedAt !== null && s.releasedAt > now) {
    return natural !== null ? Math.min(natural, s.releasedAt) : s.releasedAt;
  }
  return natural;
}
/** ReleaseMachine.ownerCanCancel */
const ownerCanCancel = (s, now) => claimIsLive(state(s, now));
// custodianCanClaim, custodianCanAuthorize and claimantCanRelease now live
// in release.js (the key holder page uses them) and are imported above.
/** DepartureRules.earliestClaim */
const earliestClaim = (s) => silenceAnchor(s) + s.policy.silenceDays * DAY;
/** DepartureRules.earliestOpening */
const earliestOpening = (s) => earliestClaim(s) + (s.policy.warningDays + s.policy.graceDays) * DAY;

// ---------------------------------------------------------------- events

/** UUID().uuidString, as EstateEventBuilder gives every event. */
const uuid = () => globalThis.crypto.randomUUID().toUpperCase();
const sha256 = async (d) => new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", d));

/** An admitted event as release.js receives it. */
function ev(kind, actorHash, at, body = null, id = uuid()) {
  const epoch = Math.trunc(at);   // RecordEvent.epochSeconds
  return {
    id, estateID: "E", kind, actorHash,
    occurredAtEpoch: epoch, occurredAt: epoch,
    body, digest: new Uint8Array(32), timestampToken: null, modifiedAt: null,
  };
}
const claimBody = (claimID, reason = "") => ({ claimID, epoch: 1, lastHeartbeatAtEpoch: null, reason });
const objectionBody = (claimID, withdrawn, note = "") => ({ claimID, withdrawn, note });
const authBody = (claimID) => ({
  claimID, epoch: 1, recordHeadDigest: new Uint8Array(0),
  assertion: {
    credentialID: new Uint8Array([1]), clientDataJSON: new Uint8Array([1]),
    authenticatorData: new Uint8Array([1]), signature: new Uint8Array([1]),
  },
  shareForClaimant: [],
});

/** Times by the actor's own clock: Swift's `timeOf: { $0.occurredAt }`. */
const byOccurredAt = (events) => new Map(events.map((e) => [e.id, e.occurredAt]));
/** Times by ReleaseFeed.effectiveTime: Swift's default when `timeOf` is nil. */
async function byEffectiveTime(events) {
  const m = new Map();
  for (const e of events) m.set(e.id, await effectiveTime(e));
  return m;
}

/**
 * A phone's FirstSeen table, only as far as the times it hands the feed.
 * Same rules as FirstSeen.swift: `note` records ids not seen before at
 * the given moment, `seed` records them at their own effective time, and
 * the time used is never earlier than first sight for the clamped kinds.
 */
const CLAMPED = new Set(["releaseClaimed", "authorization", "released", "objection", "objectionWithdrawn"]);
class Phone {
  constructor() { this.byEventID = new Map(); }
  note(events, at) { for (const e of events) if (!this.byEventID.has(e.id)) this.byEventID.set(e.id, at); }
  async seed(events) { for (const e of events) if (!this.byEventID.has(e.id)) this.byEventID.set(e.id, await effectiveTime(e)); }
  async timeOf(e) {
    const claimed = await effectiveTime(e);
    if (!CLAMPED.has(e.kind) || !this.byEventID.has(e.id)) return claimed;
    return Math.max(claimed, this.byEventID.get(e.id));
  }
  async times(events) {
    const m = new Map();
    for (const e of events) m.set(e.id, await this.timeOf(e));
    return m;
  }
}

// ================================================================ ReleaseMachineTests.swift

const fresh = () => ({
  policy: policyWith(2), estateCreatedAt: t0, lastHeartbeatAt: t0, claim: null,
  cancellations: [], objections: [], authorizations: [],
  releasedAt: null, releaseEventID: null, keyPublishedAt: null,
});
const claimAtTime = (at, id = "claim-1") => ({ id, epoch: 1, claimantHash: "brother", openedAt: at });

function releaseSilence() {
  const t = suite("release.silence");
  const s = fresh();
  let now = t0;
  t.equal(state(s, now), "active", "fresh estate is active");
  now += 89 * DAY;
  t.equal(state(s, now), "active", "day 89 still active");
  now += DAY;
  t.equal(state(s, now), "active", "exactly 90 days is still active (strictly greater)");
  now += 1;
  t.equal(state(s, now), "overdue", "one second past 90 days is overdue");
  t.equal(silentDays(s, now), 90, "silent days counts whole days");
  t.check(custodianCanClaim(s, now), "custodians may claim when overdue");
  t.check(!custodianCanClaim(s, t0), "custodians may not claim while active");
  t.equal(nextTransition(s, t0), t0 + 90 * DAY, "next transition from active is the silence deadline");
  s.lastHeartbeatAt = now;
  t.equal(state(s, now), "active", "a heartbeat makes it active again");
  const never = fresh(); never.lastHeartbeatAt = null;
  t.equal(state(never, t0 + 91 * DAY), "overdue", "no heartbeat ever: creation is the anchor");
}

function releaseHappyPath() {
  const t = suite("release.happyPath");
  const s = fresh();
  let now = t0;
  now += 100 * DAY;
  t.equal(state(s, now), "overdue", "overdue at day 100");
  s.claim = claimAtTime(now);
  t.equal(state(s, now), "warning", "a claim moves overdue to warning");
  const tl = timeline(s, now);
  t.equal(tl.warningEndsAt, now + 21 * DAY, "warnings run 21 days");
  t.equal(tl.claimOpensAt, now + 35 * DAY, "keys can be tapped after 21 + 14 days");
  t.equal(nextTransition(s, now), tl.warningEndsAt, "next transition from warning");
  now += 20 * DAY;
  t.equal(state(s, now), "warning", "day 20 of warnings");
  now += DAY;
  t.equal(state(s, now), "grace", "day 21 is grace");
  t.equal(nextTransition(s, now), tl.claimOpensAt, "next transition from grace");
  t.check(!custodianCanAuthorize(s, now, "wife"), "no taps during grace");
  now += 14 * DAY;
  t.equal(state(s, now), "claimOpen", "after grace the claim is open");
  t.check(nextTransition(s, now) === null, "claimOpen waits for people, not time");
  t.check(custodianCanAuthorize(s, now, "wife"), "wife may tap");
  s.authorizations.push({ custodianHash: "wife", at: now });
  t.equal(state(s, now), "claimOpen", "one of two is not enough");
  t.check(!custodianCanAuthorize(s, now, "wife"), "wife may not tap twice");
  now += 2 * DAY;
  s.authorizations.push({ custodianHash: "attorney", at: now });
  t.equal(state(s, now), "authorized", "two of three authorises");
  t.check(claimantCanRelease(s, now), "claimant may now combine shares");
  s.releasedAt = now;
  t.equal(state(s, now), "released", "released");
  now += 400 * DAY;
  t.equal(state(s, now), "released", "released is terminal");
  s.lastHeartbeatAt = now;
  t.equal(state(s, now), "released", "a heartbeat after release changes nothing (the key is out)");
}

function releaseHeartbeatBeatsEverything() {
  const t = suite("release.heartbeatBeatsEverything");
  const claimAt = t0 + 100 * DAY;
  function snapshotAt(st) {
    const s = fresh();
    s.claim = claimAtTime(claimAt);
    switch (st) {
      case "warning": return [s, claimAt + 5 * DAY];
      case "grace": return [s, claimAt + 25 * DAY];
      case "claimOpen": return [s, claimAt + 40 * DAY];
      case "authorized": {
        const at = claimAt + 40 * DAY;
        s.authorizations = [{ custodianHash: "wife", at }, { custodianHash: "brother", at }];
        return [s, at + DAY];
      }
      case "objected":
        s.objections = [{ custodianHash: "attorney", at: claimAt + 2 * DAY, withdrawnAt: null }];
        return [s, claimAt + 3 * DAY];
      default: throw new Error("not a live state");
    }
  }
  for (const st of ["warning", "grace", "claimOpen", "authorized", "objected"]) {
    const [s, now] = snapshotAt(st);
    t.equal(state(s, now), st, `reached ${st}`);
    t.check(ownerCanCancel(s, now), `owner can cancel from ${st}`);
    s.lastHeartbeatAt = now;
    t.equal(state(s, now), "cancelled", `heartbeat from ${st} cancels`);
    t.check(timeline(s, now) === null, `no timeline after cancel from ${st}`);
    t.check(!claimantCanRelease(s, now), `no release after cancel from ${st}`);
    t.equal(state(s, now + 90 * DAY), "cancelled", "still cancelled at 90 days");
    t.equal(state(s, now + 90 * DAY + 1), "overdue", "overdue again after fresh silence");
    t.equal(nextTransition(s, now), now + 90 * DAY, "next transition from cancelled is the new silence deadline");
  }
  const s = fresh();
  s.claim = claimAtTime(claimAt);
  s.lastHeartbeatAt = claimAt - 1;
  t.equal(state(s, claimAt + DAY), "active", "a claim one day after a heartbeat is ignored");
}

function releaseCancellation() {
  const t = suite("release.cancellation");
  const claimAt = t0 + 100 * DAY;
  const s = fresh();
  s.claim = claimAtTime(claimAt);
  const now = claimAt + 10 * DAY;
  t.equal(state(s, now), "warning", "warning before cancel");
  s.cancellations = [claimAt - DAY];
  t.equal(state(s, now), "warning", "a cancellation older than the claim does not touch it");
  s.cancellations = [now];
  t.equal(state(s, now), "overdue", "cancellation without a heartbeat kills the claim; silence still stands");
  t.check(custodianCanClaim(s, now), "a new claim may open after a bare cancellation");
  s.lastHeartbeatAt = now;
  t.equal(state(s, now), "cancelled", "cancellation with heartbeat shows cancelled");
}

function releaseObjectionPause() {
  const t = suite("release.objectionPause");
  const claimAt = t0 + 100 * DAY;
  const s = fresh();
  s.policy.objectionBehavior = "pause";
  s.claim = claimAtTime(claimAt);
  const objectAt = claimAt + 10 * DAY;
  s.objections = [{ custodianHash: "attorney", at: objectAt, withdrawnAt: null }];
  t.equal(state(s, claimAt + 9 * DAY), "warning", "before the objection: warning");
  t.equal(state(s, objectAt + DAY), "objected", "an open objection pauses");
  t.check(nextTransition(s, objectAt + DAY) === null, "paused: no timed transition");
  t.equal(state(s, objectAt + 100 * DAY), "objected", "paused forever until withdrawn");
  s.objections[0].withdrawnAt = objectAt + 5 * DAY;
  const after = objectAt + 6 * DAY;
  t.equal(state(s, after), "warning", "withdrawn: back to warning");
  const tl = timeline(s, after);
  t.equal(tl.pausedTotal, 5 * DAY, "five days of pause recorded");
  t.equal(tl.warningEndsAt, claimAt + 26 * DAY, "warning end slid by five days");
  t.equal(tl.claimOpensAt, claimAt + 40 * DAY, "claim open slid by five days");
  t.equal(state(s, claimAt + 39 * DAY), "grace", "still grace on the old open day plus 4");
  t.equal(state(s, claimAt + 40 * DAY), "claimOpen", "open on the slid day");
  const openNow = claimAt + 41 * DAY;
  s.objections.push({ custodianHash: "wife", at: openNow, withdrawnAt: null });
  t.equal(state(s, openNow + 1), "objected", "objection during claimOpen pauses");
  s.authorizations = [{ custodianHash: "brother", at: openNow + DAY }, { custodianHash: "attorney", at: openNow + DAY }];
  s.objections[1].withdrawnAt = openNow + 3 * DAY;
  const later = openNow + 4 * DAY;
  t.equal(validAuthorizations(s, later).length, 0, "taps made during a pause do not count");
  t.equal(state(s, later), "claimOpen", "after withdrawal, claim open again, nobody has validly tapped");
  s.authorizations = [{ custodianHash: "brother", at: later }, { custodianHash: "attorney", at: later }];
  t.equal(state(s, later), "authorized", "taps after the pause count");
}

function releaseObjectionVeto() {
  const t = suite("release.objectionVeto");
  const claimAt = t0 + 100 * DAY;
  const s = fresh();
  s.policy.objectionBehavior = "veto";
  s.claim = claimAtTime(claimAt);
  s.objections = [{ custodianHash: "attorney", at: claimAt + 3 * DAY, withdrawnAt: null }];
  const now = claimAt + 4 * DAY;
  t.equal(state(s, now), "objected", "veto: objected");
  t.check(timeline(s, now) === null, "veto: no timeline, the claim is dead");
  s.objections[0].withdrawnAt = claimAt + 5 * DAY;
  t.equal(state(s, claimAt + 6 * DAY), "objected", "veto: withdrawing does not revive the claim");
  t.equal(state(s, claimAt + 200 * DAY), "objected", "veto: stays objected until a new claim");
  s.authorizations = [{ custodianHash: "wife", at: claimAt + 50 * DAY }, { custodianHash: "brother", at: claimAt + 50 * DAY }];
  t.equal(state(s, claimAt + 51 * DAY), "objected", "veto: taps on a vetoed claim do nothing");
  t.check(custodianCanClaim(s, claimAt + 51 * DAY), "veto: a new claim may open because the owner is still silent");
  s.claim = claimAtTime(claimAt + 60 * DAY, "claim-2");
  s.objections = [];
  s.authorizations = [];
  t.equal(state(s, claimAt + 61 * DAY), "warning", "a new claim runs again");
}

function releaseAuthorizationRules() {
  const t = suite("release.authorizationRules");
  const claimAt = t0 + 100 * DAY;
  const s = fresh();
  s.claim = claimAtTime(claimAt);
  const open = claimAt + 35 * DAY;
  s.authorizations = [{ custodianHash: "wife", at: open }, { custodianHash: "wife", at: open + DAY }];
  t.equal(state(s, open + 2 * DAY), "claimOpen", "same custodian twice is one");
  s.authorizations = [{ custodianHash: "wife", at: open - 1 }, { custodianHash: "brother", at: open }];
  t.equal(state(s, open + DAY), "claimOpen", "a tap one second before open does not count");
  s.authorizations = [{ custodianHash: "wife", at: open }, { custodianHash: "brother", at: open }];
  t.equal(state(s, open), "authorized", "taps exactly at open count");
  s.authorizations = [{ custodianHash: "wife", at: open }, { custodianHash: "brother", at: open + 5 * DAY }];
  t.equal(state(s, open + DAY), "claimOpen", "a future-dated tap is not counted yet");
  s.policy.threshold = 3;
  s.authorizations = [{ custodianHash: "wife", at: open }, { custodianHash: "brother", at: open }, { custodianHash: "attorney", at: open }];
  t.equal(state(s, open), "authorized", "3 of 3");
  s.authorizations.pop();
  t.equal(state(s, open), "claimOpen", "2 of 3 when 3 required");
  s.policy.threshold = 1;
  s.authorizations = [{ custodianHash: "brother", at: open }];
  t.equal(state(s, open), "authorized", "1 of 3: the claimant's own tap suffices");
}

function releaseEarlyClaim() {
  const t = suite("release.earlyClaim");
  const s = fresh();
  s.claim = claimAtTime(t0 + 30 * DAY);
  t.equal(voidReason(s), "openedTooEarly", "a claim at day 30 of 90 is too early");
  t.equal(state(s, t0 + 31 * DAY), "active", "too-early claim: still active");
  t.equal(state(s, t0 + 200 * DAY), "overdue", "too-early claim never matures; overdue needs a new claim");
  t.check(custodianCanClaim(s, t0 + 200 * DAY), "a new claim is allowed");
  s.claim = claimAtTime(t0 + 90 * DAY);
  t.equal(voidReason(s), "notVoid", "a claim exactly at 90 days is allowed");
  t.equal(state(s, t0 + 89 * DAY), "active", "before the claim's own time: active");
}

/** Only the defaults: ReleasePolicy.validate is not part of release.js. */
function releasePolicy() {
  const t = suite("release.policy");
  const p = policyWith(2);
  t.equal(p.silenceDays, 90, "default silence 90");
  t.equal(p.warningDays, 21, "default warning 21");
  t.equal(p.graceDays, 14, "default grace 14");
  t.equal(p.objectionBehavior, "pause", "default objection behaviour is pause");
}

function releaseNinetySecondRun() {
  const t = suite("release.ninetySecondRun");
  let now = t0;
  const s = {
    policy: policyWith(2), estateCreatedAt: now, lastHeartbeatAt: now, claim: null,
    cancellations: [], objections: [], authorizations: [], releasedAt: null, releaseEventID: null, keyPublishedAt: null,
  };
  const seen = [state(s, now)];
  for (let i = 0; i < 8; i++) { now += 7 * DAY; s.lastHeartbeatAt = now; }
  seen.push(state(s, now));
  now += 91 * DAY;
  seen.push(state(s, now));
  s.claim = claimAtTime(now);
  seen.push(state(s, now));
  now += 21 * DAY;
  seen.push(state(s, now));
  now += 14 * DAY;
  seen.push(state(s, now));
  s.authorizations.push({ custodianHash: "wife", at: now });
  now += DAY;
  s.authorizations.push({ custodianHash: "attorney", at: now });
  seen.push(state(s, now));
  s.releasedAt = now;
  seen.push(state(s, now));
  t.equal(seen, ["active", "active", "overdue", "warning", "grace", "claimOpen", "authorized", "released"],
    "the full story runs through every state in order");
}

function releaseFutureRelease() {
  const t = suite("release.futureRelease");
  const s = fresh();
  const claimAt = t0 + 100 * DAY;
  s.claim = claimAtTime(claimAt);
  const openAt = claimAt + 35 * DAY;
  s.authorizations = [{ custodianHash: "wife", at: openAt }, { custodianHash: "attorney", at: openAt }];
  const now = openAt + DAY;
  s.releasedAt = now + 60;
  t.equal(state(s, now), "authorized", "a release dated ahead of this clock is not believed yet");
  t.equal(nextTransition(s, now), s.releasedAt, "the next change is the moment it takes effect");
  t.equal(state(s, now + 60), "released", "and at that moment it is released");
}

function releaseJudgingARelease() {
  const t = suite("release.judgingARelease");
  const s = fresh();
  const claimAt = t0 + 100 * DAY;
  s.claim = claimAtTime(claimAt);
  const opens = claimAt + 35 * DAY;
  s.authorizations = [{ custodianHash: "wife", at: opens - 60 }, { custodianHash: "attorney", at: opens - 30 }];
  t.equal(state(s, opens + DAY), "claimOpen", "the machine does not count taps seen before this phone's claim opened");
  t.check(!releaseEarned(s, opens - 1), "a release is never earned before the claim opens on this phone");
  t.check(releaseEarned(s, opens), "from that moment those taps count toward judging a release");
  const one = clone(s);
  one.authorizations.pop();
  t.check(!releaseEarned(one, opens + DAY), "one tap is not two");
  const twice = clone(s);
  twice.authorizations = [{ custodianHash: "wife", at: opens }, { custodianHash: "wife", at: opens + 60 }];
  t.check(!releaseEarned(twice, opens + DAY), "the same key holder twice is one tap");
  const alive = clone(s);
  alive.lastHeartbeatAt = claimAt + DAY;
  t.check(!releaseEarned(alive, opens + DAY), "a heartbeat after the claim: nothing is earned");
  const objected = clone(s);
  objected.objections = [{ custodianHash: "attorney", at: opens - 3_600, withdrawnAt: null }];
  t.check(!releaseEarned(objected, opens + DAY), "nothing is earned while an objection stands");
  const noThreshold = clone(s);
  noThreshold.policy.threshold = 0;
  noThreshold.authorizations = [];
  t.check(!releaseEarned(noThreshold, opens + DAY), "a rule of zero still needs one tap");
}

// ================================================================ EstateLogTests.swift

async function estatelogFeed() {
  const t = suite("estatelog.feed");
  const owner = "owner", wife = "wife", brother = "brother", attorney = "attorney";
  const events = [];
  const add = (e) => { events.push(e); };
  const policy = policyWith(2);
  add(ev("estateCreated", owner, t0, { policy: bodyPolicy(2), createdAtEpoch: t0 }));
  add(ev("heartbeat", owner, t0 + 7 * DAY));
  add(ev("heartbeat", owner, t0 + 14 * DAY));
  const claimAt = t0 + 14 * DAY + 100 * DAY;
  add(ev("releaseClaimed", brother, claimAt, claimBody("c1", "no word")));
  add(ev("objection", attorney, claimAt + 2 * DAY, objectionBody("c1", false, "wait")));
  add(ev("objectionWithdrawn", attorney, claimAt + 4 * DAY, objectionBody("c1", true, "")));
  const openAt = claimAt + 37 * DAY;
  add(ev("authorization", wife, openAt, authBody("c1")));
  add(ev("authorization", brother, openAt + DAY, authBody("c1")));

  const s = await snapshot(events, owner, policyWith(1), t0, byOccurredAt(events));
  t.equal(s.policy.threshold, 2, "policy comes from the estateCreated event");
  t.equal(s.lastHeartbeatAt, t0 + 14 * DAY, "newest heartbeat wins");
  t.equal(s.claim?.id, "c1", "the claim is found");
  t.equal(s.claim?.claimantHash, brother, "the claimant is the event's actor");
  t.equal(s.objections.length, 1, "one objection");
  t.equal(s.objections[0]?.withdrawnAt, claimAt + 4 * DAY, "the withdrawal is matched to it");
  t.equal(s.authorizations.length, 2, "two authorizations");
  t.check(s.releasedAt === null, "not released");
  t.equal(state(s, openAt + 2 * DAY), "authorized", "the feed and the machine agree: authorized");
  const withHeartbeat = [...events, ev("heartbeat", owner, openAt + 2 * DAY)];
  const s2 = await snapshot(withHeartbeat, owner, policy, t0, byOccurredAt(withHeartbeat));
  t.equal(state(s2, openAt + 3 * DAY), "cancelled", "a heartbeat after two taps still cancels");
  const reversed = [...withHeartbeat].reverse();
  const s3 = await snapshot(reversed, owner, policy, t0, byOccurredAt(reversed));
  t.equal(s3, s2, "array order does not matter");
}

async function estatelogReleaseAdmission() {
  const t = suite("estatelog.releaseAdmission");
  const owner = "owner", brother = "brother", wife = "wife";
  const realKey = new Uint8Array(32).fill(7);
  const garbage = new Uint8Array(32).fill(9);
  const policy = policyWith(1);
  const realCommitment = await sha256(realKey);

  const epochBody = (epoch, threshold, commitment) => ({
    epoch, threshold, custodianHashes: [brother, wife],
    custodianPublicKeys: [new Uint8Array(0), new Uint8Array(0)], shareCommitments: [new Uint8Array(0), new Uint8Array(0)],
    estateKeyCommitment: commitment, materialDigest: new Uint8Array(0),
  });
  const start = (threshold) => [
    ev("estateCreated", owner, t0, { policy: bodyPolicy(1), createdAtEpoch: t0 }),
    ev("epochPublished", owner, t0 + 60, epochBody(1, threshold, realCommitment)),
    ev("heartbeat", owner, t0 + 7 * DAY),
  ];
  const claim = (who, at) => ev("releaseClaimed", who, at, claimBody("c1"));
  const tap = (who, at) => ev("authorization", who, at, authBody("c1"));
  const release = (who, key, at) => ev("released", who, at, { claimID: "c1", epoch: 1, shareIndexes: [1], estateKey: key });
  const heartbeat = (at) => ev("heartbeat", owner, at);
  /** With `phone`, times are that phone's FirstSeen view, as in the app. */
  const snap = async (events, phone = null) =>
    snapshot(events, owner, policy, t0, phone ? await phone.times(events) : byOccurredAt(events));

  const base = start(1);
  const claimAt = t0 + (7 + 91) * DAY;
  const tapAt = claimAt + 35 * DAY + 3_600;
  const releaseAt = tapAt + 3_600;
  const honest = [...base, claim(brother, claimAt), tap(brother, tapAt)];

  // 1
  const early = t0 + 8 * DAY;
  const forged = await snap([...base, claim(brother, early), tap(brother, early), release(brother, realKey, early + 60)]);
  t.check(forged.releasedAt === null, "a key holder cannot release while the owner is checking in");
  t.check(state(forged, early + DAY) !== "released", "and no phone reads released");
  t.equal(forged.keyPublishedAt, early + 60, "but the published key is on record, so the owner can re-seal");

  // 2
  const good = release(brother, realKey, releaseAt);
  const s = await snap([...honest, good]);
  t.equal(s.releasedAt, releaseAt, "an earned release is honored at its own time");
  t.equal(s.releaseEventID, good.id, "and names the event the phone will open with");
  t.equal(state(s, releaseAt), "released", "the machine agrees");

  // 3
  const junk = await snap([...honest, release(brother, garbage, releaseAt)]);
  t.check(junk.releasedAt === null, "a key that misses the commitment is ignored");
  t.check(junk.keyPublishedAt === null, "and is not a published key");
  t.equal(state(junk, releaseAt), "authorized", "the estate is still authorized, not bricked");

  // 4
  const wifeFirst = await snap([...honest, release(wife, realKey, releaseAt)]);
  t.check(wifeFirst.releasedAt === null, "a release from someone other than the claimant is ignored");
  const both = await snap([...honest, release(wife, realKey, releaseAt), good]);
  t.equal(both.releaseEventID, good.id, "the claimant's own release is the one used");

  // 5
  const alive = await snap([...base, claim(brother, claimAt), heartbeat(claimAt + DAY), tap(brother, tapAt), good]);
  t.check(alive.releasedAt === null, "an owner who checked in after the claim cannot be released");

  // 6
  const late = await snap([...honest, good, heartbeat(releaseAt + DAY)]);
  t.equal(late.releasedAt, releaseAt, "a heartbeat after an earned release does not undo it");
  t.equal(state(late, releaseAt + 2 * DAY), "released", "released stays terminal");

  // 7
  const premature = await snap([...honest, release(brother, realKey, claimAt + DAY)]);
  t.equal(premature.releasedAt, tapAt, "judged at the moment the claim became authorized");

  // 8
  const future = t0 + 200 * DAY;
  const ahead = [...base, claim(brother, future), tap(brother, future + 35 * DAY + 60),
    release(brother, realKey, future + 35 * DAY + 120)];
  t.check(state(await snap(ahead), early) !== "released", "a release dated in the future is not believed today");
  const checkedIn = await snap([...ahead, heartbeat(future - 10 * DAY)]);
  t.check(checkedIn.releasedAt === null, "and once the owner checks in, it never will be");

  // 9
  const two = start(2);
  const alone = await snap([...two, claim(brother, claimAt), tap(brother, tapAt), good]);
  t.check(alone.releasedAt === null, "at a rule of two, one tap and a release are not enough");
  t.equal(state(alone, releaseAt), "claimOpen", "the claim is simply still open");
  const pair = await snap([...two, claim(brother, claimAt), tap(brother, tapAt), tap(wife, tapAt + 60), good]);
  t.equal(pair.releasedAt, releaseAt, "with both taps the same release is honored");

  // 10
  const latePhone = new Phone();
  await latePhone.seed(base);
  const heardAt = releaseAt + 10 * DAY;
  latePhone.note([...honest, good], heardAt);
  const offline = await snap([...honest, good], latePhone);
  t.equal(offline.releasedAt, heardAt + 35 * DAY, "a late phone opens once its own view of the claim has run its course");
  t.check(state(offline, heardAt + DAY) !== "released", "and not before");
  t.equal(state(offline, heardAt + 35 * DAY), "released", "then it is released");

  // 11
  const watchingPhone = new Phone();
  const checkIn = heartbeat(tapAt + 5 * DAY);
  const seenLive = [...honest, checkIn];
  await watchingPhone.seed(seenLive);
  const backdated = release(brother, realKey, tapAt + 60);
  watchingPhone.note([backdated], tapAt + 6 * DAY);
  const overruled = await snap([...seenLive, backdated], watchingPhone);
  t.check(overruled.releasedAt === null, "a backdated release cannot outrun the owner's check-in");

  // 12
  const firstTry = [...two, claim(brother, claimAt), tap(wife, tapAt), heartbeat(tapAt + DAY)];
  const secondClaimAt = tapAt + 200 * DAY;
  const reuse = [...firstTry, claim(brother, secondClaimAt), tap(brother, secondClaimAt + 35 * DAY + 60),
    release(brother, realKey, secondClaimAt + 35 * DAY + 120)];
  const farPhone = new Phone();
  await farPhone.seed(two);
  farPhone.note(reuse, secondClaimAt + 40 * DAY);
  const reused = await snap(reuse, farPhone);
  t.check(reused.claim === null, "a reused claim id is not a live claim");
  t.check(reused.releasedAt === null, "and cannot borrow the first claim's taps");

  // 13
  const copycat = claim(wife, releaseAt + DAY);
  const offlinePhone = new Phone();
  await offlinePhone.seed(base);
  const heardLate = releaseAt + 10 * DAY;
  offlinePhone.note([...honest, good, copycat], heardLate);
  const unhidden = await snap([...honest, good, copycat], offlinePhone);
  t.equal(unhidden.releasedAt, heardLate + 35 * DAY, "a copied claim id does not hide an earned release");
  t.equal(unhidden.releaseEventID, good.id, "and it is the claimant's release");

  // 14
  const newKey = new Uint8Array(32).fill(8);
  const resealed = ev("epochPublished", owner, t0 + 120, epochBody(2, 1, await sha256(newKey)));
  const stale = await snap([...base, resealed, claim(brother, claimAt), tap(brother, tapAt), good]);
  t.check(stale.releasedAt === null, "a release of an older key set is not honored");
  t.equal(stale.keyPublishedAt, releaseAt, "but its key is on record as published");

  // 15
  const witness = new Phone();
  await witness.seed([...honest, good]);
  const lateObjection = ev("objection", wife, claimAt + 2 * DAY, objectionBody("c1", false, ""));
  witness.note([lateObjection], releaseAt + DAY);
  const undone = await snap([...honest, good, lateObjection], witness);
  t.equal(undone.releasedAt, releaseAt, "an objection dated back after the release does not undo it");
  t.equal(state(undone, releaseAt + 2 * DAY), "released", "and released stays terminal");

  // 16
  const vetoCreated = ev("estateCreated", owner, t0, { policy: bodyPolicy(1, { objectionBehavior: "veto" }), createdAtEpoch: t0 });
  const vetoBase = [vetoCreated, ...base.slice(1)];
  const veto = ev("objection", wife, claimAt + DAY, objectionBody("c1", false, ""));
  const overVeto = [claim(brother, claimAt), veto, tap(brother, tapAt), good];
  const lateWitness = new Phone();
  await lateWitness.seed(vetoBase);
  lateWitness.note(overVeto, releaseAt + 10 * DAY);
  const vetoed = await snap([...vetoBase, ...overVeto], lateWitness);
  t.check(vetoed.releasedAt === null, "a late phone does not open a release published over a veto");
}

// ================================================================ FirstSeenTests.swift

async function firstseenBackdatedClaimStillWarns() {
  const t = suite("firstseen.backdatedClaimStillWarns");
  const owner = "owner";
  const heartbeat = ev("heartbeat", owner, t0, null, "hb");
  const claim = ev("releaseClaimed", "brother", t0 + 100 * DAY, claimBody("c1", "test"), "claim");
  const now = t0 + 140 * DAY;
  const seen = new Phone();
  seen.note([heartbeat], t0);
  seen.note([claim], now);

  const events = [heartbeat, claim];
  const honest = await snapshot(events, owner, policyWith(1), t0, await seen.times(events));
  t.equal(honest.claim?.openedAt, now, "the claim is dated the day this phone saw it");
  t.equal(state(honest, now), "warning", "the owner is warned from today");
  t.equal(state(honest, now + 20 * DAY), "warning", "still warning on day 20");
  t.equal(state(honest, now + 22 * DAY), "grace", "grace after the warnings");
  t.equal(state(honest, now + 36 * DAY), "claimOpen", "keys only after the full period");

  const naive = await snapshot(events, owner, policyWith(1), t0, await byEffectiveTime(events));
  t.equal(state(naive, now), "claimOpen", "without the table the backdated claim would open at once (the bug)");
}

// ================================================================ DepartureTests.swift

const departed = (keep, at) => ev("ownerDeparted", "owner", at, { keepEnvelopes: keep, departedAtEpoch: at });

/**
 * DepartureRules.departure is not in release.js. This case's check is
 * `departure(events: [fake]) == nil`; the fake entry says "cancel", so a
 * departure that counted would make openingAllowed false. openingAllowed
 * true is therefore the same statement.
 */
async function departureOnlyTheOwnerCanLeave() {
  const t = suite("departure.onlyTheOwnerCanLeave");
  const fake = ev("ownerDeparted", "keyHolder", t0, { keepEnvelopes: false, departedAtEpoch: t0 });
  t.check(await openingAllowed([fake], "owner"), "a key holder cannot make the owner look gone");
}

async function departureKeepCancelAndVoid() {
  const t = suite("departure.keepCancelAndVoid");
  const owner = "owner";
  const hb = ev("heartbeat", owner, t0);
  // `departure == nil` with no entry at all: openingAllowed's no-entry path.
  t.check(await openingAllowed([hb], owner), "no entry, nobody left");
  t.check(await openingAllowed([hb], owner), "opening is allowed while the owner is here");

  const keep = departed(true, t0 + 60);
  // `departure?.keepEnvelopes == true`: the entry stands (no later check-in), so true here means keep.
  t.check(await openingAllowed([hb, keep], owner), "keep reads as keep");
  t.check(await openingAllowed([hb, keep], owner), "keep still allows opening");

  const cancel = departed(false, t0 + 30);
  t.check(!(await openingAllowed([hb, cancel, keep], owner)), "a cancel wins over a keep, even an older one");

  // Payload "x" does not decode, so the page's body is null, as on the phone.
  const garbled = ev("ownerDeparted", owner, t0 + 90, null);
  t.check(!(await openingAllowed([hb, garbled], owner)), "an entry that does not read is treated as a cancel");

  const later = ev("heartbeat", owner, t0 + 3_600);
  // `departure == nil` with a cancel in the log: openingAllowed true is the same statement.
  t.check(await openingAllowed([hb, cancel, later], owner), "a check-in after the entry means the delete never finished");
  t.check(await openingAllowed([hb, cancel, later], owner), "and the owner is treated as here again");
}

async function departureDatesFollowTheRule() {
  const t = suite("departure.datesFollowTheRule");
  const owner = "owner";
  const policy = policyWith(1, { silenceDays: 90, warningDays: 21, graceDays: 14 });
  const created = ev("estateCreated", owner, t0, { policy: { ...policy, custodyConfirmMonths: 12 }, createdAtEpoch: t0 });
  const leftAt = t0 + 10 * 86_400;
  const keep = ev("ownerDeparted", owner, leftAt, { keepEnvelopes: true, departedAtEpoch: leftAt });
  const events = [created, keep];
  const s = await snapshot(events, owner, policy, t0, await byEffectiveTime(events));
  t.equal(silenceAnchor(s), leftAt, "the entry is the owner's last sign of life");
  t.equal(earliestClaim(s), leftAt + 90 * 86_400, "a claim can start 90 days after");
  t.equal(earliestOpening(s), leftAt + (90 + 21 + 14) * 86_400, "and they could open after the warnings and the grace");
  t.equal(state(s, leftAt + 86_400), "active", "the day after, nothing has changed in the machine");
  t.equal(state(s, leftAt + 91 * 86_400), "overdue", "after the silence, it is overdue like any other silence");
}

// ================================================================ run

const all = [
  releaseSilence, releaseHappyPath, releaseHeartbeatBeatsEverything, releaseCancellation,
  releaseObjectionPause, releaseObjectionVeto, releaseAuthorizationRules, releaseEarlyClaim,
  releasePolicy, releaseNinetySecondRun, releaseFutureRelease, releaseJudgingARelease,
  estatelogFeed, estatelogReleaseAdmission,
  firstseenBackdatedClaimStillWarns,
  departureOnlyTheOwnerCanLeave, departureKeepCancelAndVoid, departureDatesFollowTheRule,
];
for (const run of all) {
  try {
    await run();
  } catch (e) {
    check(false, `${run.name}: suite threw`, String(e?.stack ?? e));
  }
}
for (const f of failures) console.log(`FAIL ${f.name}${f.detail ? `: ${f.detail}` : ""}`);
console.log(`${checks} checks, ${failures.length} failures`);
process.exit(failures.length ? 1 : 0);
