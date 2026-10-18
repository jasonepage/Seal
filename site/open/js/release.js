// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  release.js
//
//  WHETHER A RELEASE WAS EARNED. Line by line ports of ReleaseFeed.snapshot
//  and ReleaseMachine (Seal/Estate/ReleaseFeed.swift, ReleaseMachine.swift)
//  and DepartureRules. The page must not open an estate just because a
//  published key matches the owner's commitment (rule 1). It honors a
//  release only when rules 2 and 3 also hold (audit C1), exactly as the
//  phone does, or one key holder running their own code could release
//  early and the browser would be the easy way around the check.
//
//  Times are seconds since 1970, as numbers. Where the Swift compares
//  tuples or picks `max(by:)`, the comments say which element wins ties.
//
//  HOW THE PAGE DATES EVENTS (PRODUCT.md section 15, decided 2026-10-17).
//  The phone keeps FirstSeen; a browser keeps nothing. So for the five
//  kinds FirstSeen clamps, the time is the verified token time (or the
//  actor's own time) but never earlier than the CloudKit record's
//  modification time, which Apple's server sets. `pageTimeOf` does that.

import { sha256, same } from "./bytes.js";
import { verifiedGenTime } from "./timestamp.js";

const DAY = 86_400;

// ---------------------------------------------------------------- time

/** ReleaseFeed.effectiveTime: the token's time when it verifies, else the actor's. */
export async function effectiveTime(e) {
  if (e.timestampToken) {
    const t = await verifiedGenTime(e.timestampToken, e.digest);
    if (t !== null) return t;
  }
  return e.occurredAt;
}

/** FirstSeen.clampedKinds */
export const clampedKinds = new Set(["releaseClaimed", "authorization", "released", "objection", "objectionWithdrawn"]);

/**
 * The page's stand-in for FirstSeen.timeOf. `modifiedAt` is the record's
 * modification time in seconds, from CloudKit's `modified.timestamp`.
 * Returns a map from event id to time, computed once.
 */
export async function pageTimes(events) {
  const times = new Map();
  for (const e of events) {
    const claimed = await effectiveTime(e);
    times.set(e.id, clampedKinds.has(e.kind) && typeof e.modifiedAt === "number" ? Math.max(claimed, e.modifiedAt) : claimed);
  }
  return times;
}

// ---------------------------------------------------------------- policy

/** ReleasePolicy with its defaults (ReleasePolicy.swift). */
export function policyWith(threshold, from = {}) {
  return {
    silenceDays: from.silenceDays ?? 90,
    warningDays: from.warningDays ?? 21,
    graceDays: from.graceDays ?? 14,
    threshold,
    objectionBehavior: from.objectionBehavior ?? "pause",
  };
}
const silence = (p) => p.silenceDays * DAY;
const warning = (p) => p.warningDays * DAY;
const grace = (p) => p.graceDays * DAY;

// ---------------------------------------------------------------- the feed

/** Swift (Date, String) tuple order. */
const tupleLess = (atA, idA, atB, idB) => atA < atB || (atA === atB && idA < idB);
const tupleLessEq = (atA, idA, atB, idB) => atA < atB || (atA === atB && idA <= idB);

/**
 * ReleaseFeed.base: everything but the release. `timed` is in log order,
 * each { event, at }. `focus` is { claimID, claimantHash } or null.
 */
function base(timed, ownerHash, fallbackPolicy, estateCreatedAt, focus = null) {
  let policy = { ...fallbackPolicy };
  let createdAt = estateCreatedAt;
  let lastHeartbeat = null;
  const cancellations = [];
  const claims = [];
  const objections = [];     // { claimID, o: { custodianHash, at, withdrawnAt } }
  const withdrawals = [];    // { claimID, custodianHash, at }
  const authorizations = []; // { claimID, a: { custodianHash, at } }
  const claimEvents = new Map();

  for (const { event: e, at } of timed) {
    // Any event the owner's phone signed moves the silence clock.
    if (e.actorHash === ownerHash) lastHeartbeat = Math.max(lastHeartbeat ?? at, at);
    const b = e.body;
    switch (e.kind) {
      case "estateCreated":
        if (b) { policy = { ...b.policy }; createdAt = b.createdAtEpoch; }
        break;
      case "policyChanged":
        if (b) policy = { ...b.policy };
        break;
      case "heartbeat":
        lastHeartbeat = Math.max(lastHeartbeat ?? at, at);
        break;
      case "cancellation":
        cancellations.push(at);
        break;
      case "releaseClaimed":
        if (b) {
          claims.push({ id: b.claimID, epoch: b.epoch, claimantHash: e.actorHash, openedAt: at });
          const k = b.claimID + "|" + e.actorHash;
          if (!claimEvents.has(k)) claimEvents.set(k, new Set());
          claimEvents.get(k).add(e.id);
        }
        break;
      case "objection":
        if (b && !b.withdrawn) objections.push({ claimID: b.claimID, o: { custodianHash: e.actorHash, at, withdrawnAt: null } });
        break;
      case "objectionWithdrawn":
        if (b) withdrawals.push({ claimID: b.claimID, custodianHash: e.actorHash, at });
        break;
      case "authorization":
        if (b) authorizations.push({ claimID: b.claimID, a: { custodianHash: e.actorHash, at } });
        break;
      case "epochPublished":
        // The threshold travels with the shares; the days do not.
        if (b) policy.threshold = b.threshold;
        break;
      default:
        break;   // released is judged in snapshot; the rest say nothing here
    }
  }

  const snap = {
    policy, estateCreatedAt: createdAt, lastHeartbeatAt: lastHeartbeat, claim: null,
    cancellations, objections: [], authorizations: [],
    releasedAt: null, releaseEventID: null, keyPublishedAt: null,
  };
  let chosen = null;
  if (focus) {
    chosen = claims.find((c) => c.id === focus.claimID && c.claimantHash === focus.claimantHash) ?? null;
  } else {
    // Swift max(by:) keeps the first of equal maxima.
    for (const c of claims) if (chosen === null || chosen.openedAt < c.openedAt) chosen = c;
  }
  // A claimant who opens the same claim id twice gets no claim from it.
  if (!chosen || claimEvents.get(chosen.id + "|" + chosen.claimantHash)?.size !== 1) return snap;
  snap.claim = chosen;
  const objs = objections.filter((x) => x.claimID === chosen.id).map((x) => ({ ...x.o }));
  for (const w of withdrawals) {
    if (w.claimID !== chosen.id) continue;
    // The earliest open objection by that key holder is the one withdrawn.
    const i = objs.findIndex((o) => o.custodianHash === w.custodianHash && o.withdrawnAt === null && o.at <= w.at);
    if (i >= 0) objs[i].withdrawnAt = w.at;
  }
  snap.objections = objs;
  snap.authorizations = authorizations.filter((x) => x.claimID === chosen.id).map((x) => x.a);
  return snap;
}

const MAX_PER_RELEASE = 32;
const MAX_PER_SENDER = 128;
const MAX_TOTAL = 1024;

/**
 * ReleaseFeed.snapshot over ADMITTED events. `times` maps event id to the
 * page's time for it (pageTimes). `estateCreatedAt` is the fallback the
 * phone uses for a guarded estate: the beginning of time.
 */
export async function snapshot(events, ownerHash, fallbackPolicy, estateCreatedAt, times) {
  const sorted = [...events].sort((a, b) => a.occurredAtEpoch !== b.occurredAtEpoch
    ? a.occurredAtEpoch - b.occurredAtEpoch : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const timed = sorted.map((event) => ({ event, at: times.get(event.id) }));
  const snap = base(timed, ownerHash, fallbackPolicy, estateCreatedAt);

  const commitments = new Map();   // epoch: [commitment bytes]
  const thresholds = new Map();
  const opened = new Map();        // "claimID|claimant": { count, epoch }
  const tappers = new Map();       // claimID: Set
  const firstTaps = new Map();     // "claimID|tapper": earliest time
  const objectionCounts = new Map();
  const withdrawalTimes = new Map();
  const releases = [];
  for (const t of timed) {
    const e = t.event, b = e.body;
    if (!b) continue;
    switch (e.kind) {
      case "epochPublished":
        if (e.actorHash !== ownerHash) break;
        if (!commitments.has(b.epoch)) commitments.set(b.epoch, []);
        commitments.get(b.epoch).push(b.estateKeyCommitment);
        thresholds.set(b.epoch, Math.min(thresholds.get(b.epoch) ?? b.threshold, b.threshold));
        break;
      case "releaseClaimed": {
        const k = b.claimID + "|" + e.actorHash;
        opened.set(k, { count: (opened.get(k)?.count ?? 0) + 1, epoch: b.epoch });
        break;
      }
      case "authorization": {
        if (!tappers.has(b.claimID)) tappers.set(b.claimID, new Set());
        tappers.get(b.claimID).add(e.actorHash);
        const k = b.claimID + "|" + e.actorHash;
        firstTaps.set(k, Math.min(firstTaps.get(k) ?? t.at, t.at));
        break;
      }
      case "objection":
      case "objectionWithdrawn": {
        const k = b.claimID + "|" + e.actorHash;
        if (e.kind === "objectionWithdrawn") {
          if (!withdrawalTimes.has(k)) withdrawalTimes.set(k, []);
          withdrawalTimes.get(k).push(t.at);
        } else if (!b.withdrawn) {
          objectionCounts.set(k, (objectionCounts.get(k) ?? 0) + 1);
        }
        break;
      }
      case "released":
        releases.push({ timed: t, body: b });
        break;
      default:
        break;
    }
  }

  const claimIDOf = (key) => key.slice(0, key.lastIndexOf("|"));
  const claimMoments = new Map();
  const addMoment = (claimID, at) => { if (!claimMoments.has(claimID)) claimMoments.set(claimID, []); claimMoments.get(claimID).push(at); };
  for (const [key, at] of firstTaps) addMoment(claimIDOf(key), at);
  for (const [key, list] of withdrawalTimes) {
    const matched = [...list].sort((a, b) => a - b).slice(0, objectionCounts.get(key) ?? 0);
    for (const at of matched) addMoment(claimIDOf(key), at);
  }

  let newestEpoch = null;
  for (const ep of commitments.keys()) if (newestEpoch === null || ep > newestEpoch) newestEpoch = ep;

  // Rule 1 for every release, whoever sent it and whenever.
  const genuine = [];
  for (const r of releases) {
    const list = commitments.get(r.body.epoch);
    if (!list) continue;
    const h = await sha256(r.body.estateKey);
    if (list.some((c) => same(c, h))) genuine.push(r);
  }
  snap.keyPublishedAt = genuine.length ? Math.min(...genuine.map((g) => g.timed.at)) : null;

  // Rules 2 and 3: necessary conditions first, then the earliest per sender and claim.
  const earliest = new Map();
  for (const g of genuine) {
    const sender = g.timed.event.actorHash;
    const opening = opened.get(g.body.claimID + "|" + sender);
    if (g.body.epoch !== newestEpoch || !opening || opening.count !== 1 || opening.epoch !== g.body.epoch) continue;
    if ((tappers.get(g.body.claimID)?.size ?? 0) < Math.max(1, thresholds.get(g.body.epoch) ?? snap.policy.threshold)) continue;
    const key = sender + "|" + g.body.claimID;
    const have = earliest.get(key);
    if (have && tupleLessEq(have.timed.at, have.timed.event.id, g.timed.at, g.timed.event.id)) continue;
    earliest.set(key, g);
  }
  const currentClaimID = snap.claim?.id ?? null;
  const ordered = [...earliest.values()].sort((a, b) => {
    const ac = a.body.claimID === currentClaimID, bc = b.body.claimID === currentClaimID;
    if (ac !== bc) return ac ? -1 : 1;
    return tupleLess(a.timed.at, a.timed.event.id, b.timed.at, b.timed.event.id) ? -1
      : tupleLess(b.timed.at, b.timed.event.id, a.timed.at, a.timed.event.id) ? 1 : 0;
  });

  let budget = MAX_TOTAL;
  const left = new Map();
  for (const { timed: candidate, body } of ordered) {
    if (budget <= 0) break;
    const sender = candidate.event.actorHash;
    let senderLeft = left.get(sender) ?? MAX_PER_SENDER;
    if (senderLeft <= 0) continue;
    let ownBudget = MAX_PER_RELEASE;
    const moments = new Set((claimMoments.get(body.claimID) ?? []).filter((m) => m > candidate.at));
    moments.add(candidate.at);
    const tried = new Set();
    while (budget > 0 && senderLeft > 0 && ownBudget > 0) {
      let moment = null;
      for (const m of moments) if (!tried.has(m) && (moment === null || m < moment)) moment = m;
      if (moment === null) break;
      tried.add(moment);
      budget--; senderLeft--; ownBudget--;
      const then = base(timed.filter((t) => t.at <= moment), ownerHash, fallbackPolicy, estateCreatedAt,
        { claimID: body.claimID, claimantHash: sender });
      const c = then.claim;
      if (!c || c.id !== body.claimID || c.epoch !== body.epoch || c.claimantHash !== sender) continue;
      if (releaseEarned(then, moment)) {
        snap.releasedAt = moment;
        snap.releaseEventID = candidate.event.id;
        return snap;
      }
      // Not open yet: judge again the moment it opens, unless an objection stands.
      if (!hasOpenObjection(then, moment)) {
        const opens = timeline(then, moment)?.claimOpensAt;
        if (opens !== undefined && opens > moment) moments.add(opens);
      }
    }
    left.set(sender, senderLeft);
  }
  return snap;
}

// ---------------------------------------------------------------- the machine

const silenceAnchor = (s) => s.lastHeartbeatAt ?? s.estateCreatedAt;

/** ReleaseMachine.voidReason, as a string ("notVoid" when the claim stands). */
export function voidReason(s) {
  const claim = s.claim;
  if (!claim) return "notVoid";
  if (s.lastHeartbeatAt !== null && s.lastHeartbeatAt >= claim.openedAt) return "heartbeatAfterClaim";
  if (s.cancellations.some((c) => c >= claim.openedAt)) return "cancelledByOwner";
  if (s.policy.objectionBehavior === "veto" && s.objections.some((o) => o.at >= claim.openedAt)) return "vetoed";
  if (claim.openedAt < silenceAnchor(s) + silence(s.policy)) return "openedTooEarly";
  return "notVoid";
}

export function pausedTotal(s, until) {
  if (s.policy.objectionBehavior !== "pause" || !s.claim) return 0;
  let total = 0;
  for (const o of s.objections) {
    if (!(o.at >= s.claim.openedAt && o.at < until)) continue;
    const end = Math.min(o.withdrawnAt ?? until, until);
    total += Math.max(0, end - o.at);
  }
  return total;
}

export function hasOpenObjection(s, now) {
  if (s.policy.objectionBehavior !== "pause" || !s.claim) return false;
  return s.objections.some((o) => {
    if (!(o.at >= s.claim.openedAt && o.at <= now)) return false;
    return o.withdrawnAt !== null ? o.withdrawnAt > now : true;
  });
}

export function timeline(s, now) {
  if (!s.claim || voidReason(s) !== "notVoid") return null;
  const paused = pausedTotal(s, now);
  const warningEndsAt = s.claim.openedAt + warning(s.policy) + paused;
  return { claimOpenedAt: s.claim.openedAt, warningEndsAt, claimOpensAt: warningEndsAt + grace(s.policy), pausedTotal: paused };
}

export function validAuthorizations(s, now) {
  if (!s.claim || voidReason(s) !== "notVoid") return [];
  const seen = new Set();
  const out = [];
  // Swift's sort is not stable, but distinct taps by one key holder at one
  // instant cannot both count, so the order among equal times never matters.
  for (const a of [...s.authorizations].sort((x, y) => x.at - y.at)) {
    if (a.at > now) continue;
    const openAt = s.claim.openedAt + warning(s.policy) + grace(s.policy) + pausedTotal(s, a.at);
    if (a.at < openAt || hasOpenObjection(s, a.at) || seen.has(a.custodianHash)) continue;
    seen.add(a.custodianHash);
    out.push(a);
  }
  return out;
}

export function state(s, now) {
  if (s.releasedAt !== null && s.releasedAt <= now) return "released";
  const overdue = now - silenceAnchor(s) > silence(s.policy);
  const claim = s.claim;
  if (!claim) return overdue ? "overdue" : "active";
  switch (voidReason(s)) {
    case "heartbeatAfterClaim":
    case "cancelledByOwner":
      return overdue ? "overdue" : "cancelled";
    case "vetoed":
      return "objected";
    case "openedTooEarly":
      return overdue ? "overdue" : "active";
    default:
      break;
  }
  if (now < claim.openedAt) return overdue ? "overdue" : "active";
  if (hasOpenObjection(s, now)) return "objected";
  const t = timeline(s, now);
  if (!t) return "overdue";
  if (now < t.warningEndsAt) return "warning";
  if (now < t.claimOpensAt) return "grace";
  return validAuthorizations(s, now).length >= s.policy.threshold ? "authorized" : "claimOpen";
}

export function releaseEarned(s, moment) {
  const claim = s.claim;
  if (!claim || voidReason(s) !== "notVoid") return false;
  const t = timeline(s, moment);
  if (!t || moment < t.claimOpensAt || hasOpenObjection(s, moment)) return false;
  const tappers = new Set();
  for (const a of s.authorizations) {
    if (a.at >= claim.openedAt && a.at <= moment && !hasOpenObjection(s, a.at)) tappers.add(a.custodianHash);
  }
  return tappers.size >= Math.max(1, s.policy.threshold);
}

export const silentDays = (s, now) => Math.max(0, Math.floor((now - silenceAnchor(s)) / DAY));

// ---------------------------------------------------------------- departure

/**
 * DepartureRules.openingAllowed: false when the owner deleted their
 * account and cancelled the envelopes, unless they came back after.
 */
export async function openingAllowed(events, ownerHash) {
  const mine = events.filter((e) => e.kind === "ownerDeparted" && e.actorHash === ownerHash);
  if (!mine.length) return true;
  let latest = null;
  for (const e of mine) if (latest === null || tupleLess(latest.occurredAtEpoch, latest.id, e.occurredAtEpoch, e.id)) latest = e;
  const leftAt = await effectiveTime(latest);
  for (const e of events) {
    if (e.kind === "heartbeat" && e.actorHash === ownerHash && (await effectiveTime(e)) > leftAt) return true;
  }
  // A departure whose body does not decode counts as a cancel, as on the phone.
  return !mine.some((e) => (e.body?.keepEnvelopes ?? false) === false);
}

// ---------------------------------------------------------------- what a key holder may do

/** ReleaseMachine.custodianCanClaim */
export function custodianCanClaim(s, now) {
  if (state(s, now) === "overdue") return true;
  // After a veto, a new claim may open once the silence period stands again.
  if (voidReason(s) === "vetoed") return now - silenceAnchor(s) > silence(s.policy);
  return false;
}

/** ReleaseMachine.custodianCanAuthorize */
export function custodianCanAuthorize(s, now, custodianHash) {
  const st = state(s, now);
  if (st !== "claimOpen" && st !== "authorized") return false;
  return !validAuthorizations(s, now).some((a) => a.custodianHash === custodianHash);
}

/** ReleaseMachine.claimantCanRelease */
export const claimantCanRelease = (s, now) => state(s, now) === "authorized";
