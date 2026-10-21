// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  app.js
//
//  The web page for recipients and key holders (PRODUCT.md section 15,
//  1.2a and 1.2b). Two taps of the security key someone registered for
//  this person: the first says which key it is, the second hands over the
//  key's secret (WebAuthn PRF) that unlocks this person's private keys, in
//  memory only. Then the page finds every estate that named them, judges
//  each release the way the phone does, opens only what was released, and
//  lets a key holder confirm, claim, object, tap and combine, each one an
//  entry signed here and sent through the relay (worker/index.js).
//
//  Everything the writer wrote is shown with textContent, never as HTML.
//  Nothing is written to browser storage. Closing the tab forgets it all.

import { config } from "./config.js";
import { toHex, sha256, same, utf8, concat, toB64, fromB64 } from "./bytes.js";
import { CloudKit, bytesField, stringField } from "./cloudkit.js";
import { unlockSponsored } from "./crypto.js";
import { signingKeyFrom } from "./signer.js";
import { buildAction, publish } from "./keyholder.js";
import { custodianCanClaim, custodianCanAuthorize, claimantCanRelease, voidReason, silentDays } from "./release.js";
import { fetchIdentity, findInvites, judgeEstate, openEstate, openMedia, waitingFor } from "./estate.js";
import { verifiedDevices, parseAssertion, verifyAssertion, clientDataChallengeMatches } from "./identity.js";
import { phrase } from "./words.js";

const main = document.getElementById("app");
/** The signed-in person, in memory only, for this tab. */
let session = null;
/**
 * Credentials this tab was told to pass over ("Not Karen?"). One security
 * key can hold more than one Seal identity, and with a list of IDs the key
 * answers with the first it holds, so leaving one out is the only way to
 * reach the next. In memory only.
 */
const skipIDs = [];

// ---------------------------------------------------------------- tiny DOM

function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") el.className = v;
    else if (k === "on") for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
    else if (v !== null && v !== undefined && v !== false) el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}
const show = (...nodes) => { main.replaceChildren(...nodes.flat().filter((n) => n !== null && n !== undefined && n !== false)); window.scrollTo(0, 0); };
const working = (line) => show(h("p", { class: "lede", role: "status" }, line));

function problem(line, again = true) {
  show(
    h("div", { class: "note", role: "alert" }, h("p", {}, line)),
    again ? h("button", { class: "cta", type: "button", on: { click: start } }, "Try again") : null,
  );
}

const random = (n) => crypto.getRandomValues(new Uint8Array(n));
const nowSeconds = () => Date.now() / 1000;
const dateLine = (s) => new Date(s * 1000).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });

// ---------------------------------------------------------------- start

function start() {
  if (config.development) document.title = "TEST DATABASE: " + document.title;
  if (!config.apiToken) {
    problem("This page is not switched on yet. Your envelopes are safe, and the Seal app on an iPhone opens them today.", false);
    return;
  }
  if (!window.PublicKeyCredential || !navigator.credentials?.get) {
    problem("This browser cannot talk to a security key. Try a current Chrome, Edge, Firefox or Safari.", false);
    return;
  }
  show(
    config.development ? h("div", { class: "note", role: "note" }, h("p", {}, h("b", {}, "Test database. "), "This reads the data debug builds write, not real envelopes.")) : null,
    h("p", { class: "lede" }, "Have the security key you were given ready. If it has a PIN, you will need that too."),
    h("button", { class: "cta big", type: "button", on: { click: () => run().catch(failed) } }, "Use my security key"),
    h("p", { class: "small" }, "You will tap it twice. Nothing is saved in this browser."),
  );
}

function failed(err) {
  if (err?.name === "NotAllowedError") return problem("The key was not tapped, or the request was cancelled. Nothing was opened.");
  if (err?.name === "SecurityError") return problem("This page has to be opened at sealmessenger.com for your key to answer.", false);
  problem(err?.message || "Something went wrong. Nothing was opened.");
}

// ---------------------------------------------------------------- the taps

/**
 * TombstoneProof.markerCounts: a "tomb.<hash>" marker retires an identity
 * only when its proof is a tap by that identity's own root key over the
 * delete challenge. Anyone can write a record, so a marker without one is
 * ignored, the same as on every phone.
 */
async function markerCounts(hash, proofBytes, publicKey) {
  if (!publicKey) return true;
  try {
    const proof = JSON.parse(new TextDecoder().decode(proofBytes));
    const a = parseAssertion(utf8(JSON.stringify(proof.assertion)));
    if (!a || toHex(await sha256(a.credentialID)) !== hash) return false;
    const challenge = await sha256(concat(utf8("seal.identity.delete.v1"), fromB64(proof.nonce)));
    return clientDataChallengeMatches(a.clientDataJSON, challenge) && await verifyAssertion(a, publicKey);
  } catch {
    return false;
  }
}

async function credentialIDs(ck) {
  const records = await ck.query("Identity", null, null, { desiredKeys: ["credentialID", "tier", "publicKey", "revocations"], maxPages: 50 });
  const live = new Map();
  const markers = new Map();
  for (const r of records) {
    if (r.recordName.startsWith("tomb.")) { markers.set(r.recordName.slice(5), bytesField(r, "revocations")); continue; }
    if (stringField(r, "tier") !== "verified") continue;
    const id = bytesField(r, "credentialID");
    if (id) live.set(r.recordName, { id, publicKey: bytesField(r, "publicKey") });
  }
  const ids = [];
  for (const [hash, { id, publicKey }] of live) {
    // A retired identity stays out of the list, so a key that holds it and
    // another one answers with the other (a web retire cannot flip the live
    // record, only its creator can, so the marker is what says it is gone).
    if (markers.has(hash) && await markerCounts(hash, markers.get(hash), publicKey)) continue;
    ids.push(id);
  }
  return ids;
}

const keyRequest = (ids, extensions) => ({
  publicKey: {
    rpId: config.rpId,
    challenge: random(32),
    allowCredentials: ids.map((id) => ({ type: "public-key", id, transports: ["usb", "nfc"] })),
    userVerification: "preferred",
    timeout: 120_000,
    ...(extensions ? { extensions } : {}),
  },
});

async function run() {
  const ck = new CloudKit(config);
  working("Getting ready…");
  const ids = (await credentialIDs(ck)).filter((id) => !skipIDs.some((s) => same(s, id)));
  if (!ids.length) throw new Error("Seal's directory could not be read. Try again in a minute.");

  working("Tap your security key.");
  const first = await navigator.credentials.get(keyRequest(ids));
  const credentialID = new Uint8Array(first.rawId);
  const myHash = toHex(await sha256(credentialID));

  working("Looking up your key…");
  const me = await fetchIdentity(ck, myHash);
  if (!me) throw new Error("This key is not registered with Seal, or it was retired. Nothing was opened.");
  // Only a key registered for someone, with its locked device, opens here.
  const verified = await verifiedDevices(me.root, me.endorsements);
  const sponsored = verified.find((d) => d.lockedPrivate && d.prfSalt);
  if (!sponsored) {
    // An app user's envelopes open only on their own phone, but the page
    // can still say, from the public record, that something is waiting.
    working("Checking what is waiting for you…");
    return showWaiting(me, await waitingFor(ck, myHash, nowSeconds()), ck, credentialID);
  }

  working("Tap your security key again to unlock.");
  const second = await navigator.credentials.get(keyRequest([credentialID], { prf: { eval: { first: sponsored.prfSalt } } }));
  if (!same(new Uint8Array(second.rawId), credentialID)) throw new Error("A different key answered the second time. Use the same key for both taps.");
  const prf = second.getClientExtensionResults?.().prf?.results?.first;
  if (!prf) throw new Error("This browser or key did not hand over the key's secret. Try a current Chrome, Edge, Firefox or Safari, and make sure the key's PIN is set.");

  let unlocked;
  try {
    unlocked = await unlockSponsored(sponsored.lockedPrivate, new Uint8Array(prf), sponsored.prfSalt);
  } catch {
    throw new Error("This key does not unlock this identity. Nothing was opened.");
  }
  // The keys that unlocked must be the ones the person's own key endorsed.
  if (!same(unlocked.kemBundle, sponsored.kemBundlePublicKeys)) throw new Error("The unlocked keys do not match what the directory lists. Nothing was opened.");
  const kems = [unlocked.kem];
  // The same device's signing half, for key holders (1.2b). Checked against
  // the public half the endorsement commits to before it signs anything.
  const signer = await signingKeyFrom(unlocked.signingKey, sponsored.devicePublicKey);
  session = { ck, me, kems, holder: { hash: myHash, credentialID, signer, kems } };
  await refresh();
}

/**
 * The signal for an app user's key: yes, something is waiting, and from
 * whom. Nothing is opened here; their envelopes are wrapped to their phone.
 */
function showWaiting(me, found, ck, credentialID) {
  const name = me.root.displayName;
  const keyTools = h("div", { class: "keytools" },
    h("p", { class: "small" }, `Not ${name}? One key can hold more than one identity.`),
    h("p", {},
      h("button", { class: "cta ghost", type: "button", on: { click: () => { skipIDs.push(credentialID); run().catch(failed); } } }, "Use another identity on this key"),
      h("button", { class: "cta ghost", type: "button", on: { click: () => confirmRetire(me, found, ck, credentialID) } }, `Retire ${name} from this key`),
    ),
  );
  const appLine = h("p", {}, "Open Seal on your iPhone or iPad to read them. This page only opens envelopes for keys that someone registered for you.");
  const store = h("p", {}, h("a", { class: "cta ghost", href: "https://apps.apple.com/app/id6779471126" }, "Get Seal on the App Store"));
  const envelopes = found.filter((f) => f.sealed && !f.keyHolder);
  if (!found.length) {
    return show(
      h("p", { class: "lede" }, `Signed in as ${me.root.displayName}.`),
      h("p", {}, "Nothing is waiting for you yet. When someone seals envelopes to you, it shows here."),
      keyTools,
    );
  }
  const rows = found.map((f) => {
    const who = f.ownerName || "Someone";
    const what = f.keyHolder
      ? `${who}: you hold one of the keys to their envelopes.`
      : f.sealed ? `${who}: an envelope is waiting for you.` : `${who}: added you, but has not sealed yet.`;
    return h("li", {}, what, h("br"), h("span", { class: "small" }, stateLine(f.judged, nowSeconds())));
  });
  show(
    h("div", { class: "waiting" },
      h("img", { src: "/seal-mark.png", alt: "", width: 88 }),
      h("h2", {}, envelopes.length === 1 ? "Yes. An envelope is waiting for you."
        : envelopes.length > 1 ? `Yes. ${envelopes.length} envelopes are waiting for you.`
        : "Yes. You are part of someone's Seal."),
    ),
    h("p", { class: "small" }, `Signed in as ${me.root.displayName}.`),
    h("ul", { class: "waitlist" }, rows),
    appLine,
    store,
    keyTools,
  );
}

// ---------------------------------------------------------------- retire a key

/**
 * The web version of the app's "An old key is in the way? Retire it"
 * (RetireKeyCeremony.swift): one tap over the delete challenge, sent to
 * the relay, which checks it and writes the same write-once marker the
 * phone writes (worker/index.js, relayRetire). For a key whose identity
 * was made on a phone that is gone.
 */
function confirmRetire(me, found, ck, credentialID) {
  const name = me.root.displayName;
  const holds = found.filter((f) => f.keyHolder).map((f) => f.ownerName || "someone");
  show(
    h("h2", {}, `Retire ${name} from this key?`),
    h("p", {}, `This deletes the Seal identity "${name}" for good. Nobody can sign in as ${name} again, with this key or any other, and it cannot be undone.`),
    holds.length ? h("div", { class: "note", role: "note" }, h("p", {}, `${name} holds one of the keys to ${holds.join(" and ")}'s envelopes. That key stops counting. The writer should open Seal and pick another key holder.`)) : null,
    h("p", {}, "Use this when the phone that made this identity is gone and the key is needed for someone else."),
    h("p", {},
      h("button", { class: "cta", type: "button", on: { click: () => retire(me, ck, credentialID).catch(failed) } }, `Retire ${name}`),
      h("button", { class: "cta ghost", type: "button", on: { click: () => run().catch(failed) } }, "Back"),
    ),
  );
}

async function retire(me, ck, credentialID) {
  const name = me.root.displayName;
  const nonce = random(32);
  const challenge = await sha256(concat(utf8("seal.identity.delete.v1"), nonce));
  working("Tap your security key to retire it.");
  const cred = await navigator.credentials.get({ publicKey: {
    rpId: config.rpId, challenge, userVerification: "preferred", timeout: 120_000,
    allowCredentials: [{ type: "public-key", id: credentialID, transports: ["usb", "nfc"] }],
  } });
  if (!same(new Uint8Array(cred.rawId), credentialID)) throw new Error("A different key answered. Nothing was changed.");
  const r = cred.response;
  const body = { retire: { nonce: toB64(nonce), assertion: {
    credentialID: toB64(credentialID),
    clientDataJSON: toB64(new Uint8Array(r.clientDataJSON)),
    authenticatorData: toB64(new Uint8Array(r.authenticatorData)),
    signature: toB64(new Uint8Array(r.signature)),
  } } };
  working("Sending it to Apple through the relay…");
  const res = await fetch("/relay/retire", {
    method: "POST", headers: { "Content-Type": "text/plain;charset=UTF-8" },
    body: JSON.stringify(body), credentials: "omit", cache: "no-store",
  });
  const answer = await res.json().catch(() => null);
  if (!res.ok || !answer?.ok) throw new Error(answer?.message ?? `The relay did not take it (HTTP ${res.status}). Nothing was changed.`);
  // Apple's copy, not the relay's word.
  let back = null;
  for (let i = 0; i < 6 && !back; i++) {
    back = await ck.record(`tomb.${answer.hash}`).catch(() => null);
    if (!back) await new Promise((ok) => setTimeout(ok, 1500));
  }
  if (!back) throw new Error("The relay said it saved this, but Apple's copy could not be found yet. Try again in a minute.");
  session = null;
  show(
    h("div", { class: "note", role: "status" }, h("p", {}, h("b", {}, "Retired. "), `This key no longer holds ${name}'s Seal identity. You can register it for someone else now.`)),
    h("button", { class: "cta", type: "button", on: { click: () => run().catch(failed) } }, "Sign in with this key again"),
  );
}

/** Everything this person is part of, judged again from the record. */
async function refresh() {
  const { ck, me, kems } = session;
  working("Finding what you are part of…");
  const invites = await findInvites(ck, me.root.credentialIDHash, kems);
  if (!invites.length) {
    show(h("p", { class: "lede" }, `Signed in as ${me.root.displayName}.`), h("p", {}, "Nobody has written envelopes to you or made you a key holder yet, or the writer has not sealed. Check again later."));
    return;
  }
  const byEstate = new Map();
  for (const i of invites) {
    const have = byEstate.get(i.estateID);
    if (have) have.roles.add(i.role); else byEstate.set(i.estateID, { ...i, roles: new Set([i.role]) });
  }
  const now = nowSeconds();
  const judged = [];
  for (const invite of byEstate.values()) {
    working(`Checking the record for ${invite.ownerName || "a writer"}…`);
    const j = await judgeEstate(ck, invite, now);
    j.roles = invite.roles;
    // A key holder who is also a recipient has one invite record, and the
    // phone writes the recipient one last, so the invite alone can lose the
    // key holder role. The writer's signed key list is the real answer.
    if (j.epoch?.custodianHashes.includes(me.root.credentialIDHash)) j.roles.add("custodian");
    judged.push(j);
  }
  await list(judged, now);
}

// ---------------------------------------------------------------- the list

function stateLine(j, now) {
  if (j.problem === "owner") return "The writer's record could not be checked, so nothing here is opened.";
  if (!j.openingAllowed) return "The writer cancelled these envelopes when they deleted their Seal account. They can never be opened.";
  switch (j.state) {
    case "released": return "Released.";
    case "warning":
    case "grace": return `Not open yet. A key holder started the release, and the writer is being warned${j.timeline ? `. Keys can be tapped from ${dateLine(j.timeline.claimOpensAt)}` : ""}.`;
    case "claimOpen": return "The key holders are being asked to tap their keys.";
    case "authorized": return "Enough key holders have tapped. The one who started the claim can combine the keys.";
    case "objected": return "A key holder objected, so the release is on hold.";
    case "overdue": return `The writer has been quiet longer than their rule allows (${silentDays(j.snapshot, now)} days). Nothing opens unless a key holder starts a claim and the warnings run out.`;
    case "cancelled": return "The writer stopped the last claim by checking in. Still sealed.";
    default: return "Still sealed. Nothing opens unless the writer goes quiet for a long time and their key holders agree.";
  }
}

/** The key holder's buttons, each one the phone's own guard. */
function holderActions(j, now) {
  const me = session.holder.hash;
  const s = j.snapshot;
  if (!j.epoch?.custodianHashes.includes(me)) return [h("p", { class: "small" }, "You were made a key holder, but the writer has not sealed you in yet.")];
  const out = [];
  const myOpen = s?.claim && s.objections.some((o) => o.custodianHash === me && o.withdrawnAt === null);
  if (s && j.openingAllowed && custodianCanClaim(s, now)) out.push(actionButton(j, "claim", "Start a claim"));
  if (s && j.openingAllowed && custodianCanAuthorize(s, now, me)) out.push(actionButton(j, "tap", "Tap my key to release", true));
  if (s?.claim && s.claim.claimantHash === me && j.openingAllowed && claimantCanRelease(s, now)) out.push(actionButton(j, "release", "Combine the keys and release", true));
  if (s?.claim && voidReason(s) === "notVoid" && j.state !== "released") {
    out.push(myOpen ? actionButton(j, "withdraw", "Withdraw my objection") : actionButton(j, "object", "Object to this claim"));
  }
  if (j.state !== "released") out.push(actionButton(j, "confirmCustody", "Confirm I still have my key"));
  return out;
}

const ASK = {
  claim: { line: "This starts the release. The writer is warned every day for weeks, and one check-in from them stops it. Only do this if you believe they are gone.", field: "Why are you starting it? (everyone in the record can read this)", go: "Start the claim" },
  object: { line: "This puts the release on hold while your objection stands.", field: "A note (everyone in the record can read this)", go: "Object" },
  withdraw: { line: "This takes back your objection. The countdown goes on.", go: "Withdraw it" },
  tap: { line: "Your key, tapped here, is one of the keys that opens the envelopes. You will tap it once more to sign.", go: "Tap my key" },
  release: { line: "This combines the keys and opens the envelopes for everyone they were written to. It cannot be undone.", go: "Release" },
  confirmCustody: { line: "This tells the writer you still have your key. Tap it once more to sign.", go: "Confirm" },
};

function actionButton(j, action, label, primary = false) {
  return h("button", { class: primary ? "cta" : "cta ghost", type: "button", on: { click: () => askFirst(j, action) } }, label);
}

function askFirst(j, action) {
  const a = ASK[action];
  const input = a.field ? h("textarea", { rows: 3, maxlength: 500, "aria-label": a.field }) : null;
  show(
    h("h2", {}, `From ${j.ownerName || "someone"}`),
    h("p", {}, a.line),
    a.field ? h("p", { class: "small" }, a.field) : null,
    input,
    h("p", {},
      h("button", { class: "cta", type: "button", on: { click: () => act(j, action, input?.value?.trim() ?? "").catch(failedAction) } }, a.go),
      h("button", { class: "cta ghost", type: "button", on: { click: () => refresh().catch(failed) } }, "Back"),
    ),
  );
}

async function act(j, action, text) {
  working(action === "tap" || action === "confirmCustody" ? "Tap your security key." : "Signing…");
  const built = await buildAction(action, {
    ck: session.ck, judged: j, me: session.holder, now: nowSeconds(),
    reason: text, note: text, rpId: config.rpId,
  });
  working("Sending it to Apple through the relay, then checking Apple's copy…");
  await publish(session.ck, built);
  show(
    h("div", { class: "note", role: "status" }, h("p", {}, h("b", {}, "Saved. "), "Apple has it, exactly as you signed it. Every phone in this estate will check it for itself.")),
    h("button", { class: "cta", type: "button", on: { click: () => refresh().catch(failed) } }, "Back to the list"),
  );
}

function failedAction(err) {
  if (err?.name === "NotAllowedError") return problem("The key was not tapped, or the request was cancelled. Nothing was sent.");
  problem(err?.message || "Something went wrong. Nothing was sent.");
}

async function list(judged, now) {
  const { ck } = session;
  const items = [];
  for (const j of judged) {
    const owner = await fetchIdentity(ck, j.ownerHash, { history: true }).catch(() => null);
    const words = owner ? await phrase(owner.root.publicKey) : null;
    const recipient = j.roles.has("recipient");
    const holder = j.roles.has("custodian");
    const open = recipient && j.state === "released" && j.openingAllowed;
    items.push(h("div", { class: "card" },
      h("h3", {}, `From ${j.ownerName || "someone"}`),
      h("p", { class: "small" }, [recipient ? "They wrote to you." : null, holder ? "You hold one of their keys." : null].filter(Boolean).join(" ")),
      words ? h("p", { class: "small" }, `Their words: ${words}. In the app these show under their seal as "Your words". If you know theirs, check they match.`) : null,
      h("p", {}, stateLine(j, now)),
      open ? h("button", { class: "cta", type: "button", on: { click: () => envelopes(ck, session.me, session.kems, j, now).catch(failed) } }, "Open my envelopes") : null,
      holder && j.problem !== "owner" ? holderActions(j, now) : null,
    ));
  }
  show(
    h("p", { class: "lede" }, `Signed in as ${session.me.root.displayName}.`),
    ...items,
    h("p", { class: "small" }, "Nothing is saved in this browser. When you are done, close the tab."),
  );
}

// ---------------------------------------------------------------- the envelopes

function sniffImage(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return "image/jpeg";
  if (bytes[0] === 0x89 && bytes[1] === 0x50) return "image/png";
  if (bytes.length > 12 && String.fromCharCode(...bytes.subarray(4, 12)).startsWith("ftyphei")) return "image/heic";
  return "application/octet-stream";
}
const blobURL = (bytes, type) => URL.createObjectURL(new Blob([bytes], { type }));

function downloadLink(bytes, name, type = "application/octet-stream") {
  return h("a", { href: blobURL(bytes, type), download: name }, `Save ${name}`);
}

/** A media item that loads when asked, never before. */
function mediaBlock(ck, j, entry, item, label) {
  const box = h("div", { class: "media" });
  const load = async () => {
    box.replaceChildren(h("p", { class: "small", role: "status" }, "Opening…"));
    try {
      const bytes = await openMedia(ck, j.estateID, entry, item);
      if (item.kind === "photo") {
        const type = sniffImage(bytes);
        box.replaceChildren(
          type === "image/heic" ? h("p", { class: "small" }, "This photo is in Apple's HEIC format, which this browser may not show.") : null,
          h("img", { src: blobURL(bytes, type), alt: "A photo from the envelope" }),
          h("p", { class: "small" }, downloadLink(bytes, `photo-${item.blobID.slice(0, 8)}${type === "image/png" ? ".png" : type === "image/heic" ? ".heic" : ".jpg"}`, type)),
        );
      } else if (item.kind === "voice") {
        box.replaceChildren(h("audio", { controls: true, src: blobURL(bytes, "audio/mp4") }), h("p", { class: "small" }, downloadLink(bytes, "voice-message.m4a", "audio/mp4")));
      } else if (item.kind === "video") {
        box.replaceChildren(h("video", { controls: true, playsinline: true, src: blobURL(bytes, "video/mp4") }), h("p", { class: "small" }, downloadLink(bytes, "video.mov", "video/quicktime")));
      } else {
        box.replaceChildren(h("p", {}, downloadLink(bytes, item.fileName || "file")));
      }
    } catch (err) {
      box.replaceChildren(h("p", { class: "small" }, err?.message || "That file could not be opened."));
    }
  };
  box.append(h("button", { class: "cta ghost", type: "button", on: { click: load } }, label));
  return box;
}

const CARD_LABELS = {
  cryptoAddress: "Crypto address", paymentInstructions: "Payment instructions", statement: "Statement",
  password: "Password or login", seedPhrase: "Seed phrase", combination: "Combination or code", location: "Where to find it",
};
const chunked = (s) => [...s].map((c, i) => (i > 0 && i % 4 === 0 ? " " + c : c)).join("");

function secretBlock(card) {
  const value = h("p", { class: "secret" }, "Hidden until you show it.");
  const line = h("p", { class: "small", role: "status" });
  let shown = false;
  const showBtn = h("button", { class: "cta ghost", type: "button", on: { click: () => {
    shown = !shown;
    value.textContent = shown ? (card.cardType === "cryptoAddress" ? chunked(card.value) : card.value) : "Hidden until you show it.";
    showBtn.textContent = shown ? "Hide" : "Show";
  } } }, "Show");
  const copyBtn = h("button", { class: "cta ghost", type: "button", on: { click: async () => {
    try {
      await navigator.clipboard.writeText(card.value);
      const ends = card.value.length <= 16 ? card.value : `${card.value.slice(0, 6)}…${card.value.slice(-6)}`;
      const what = shown ? `Copied ${ends}.` : "Copied.";
      line.textContent = `${what} A browser cannot clear the clipboard for you, so copy something else after you paste.`;
    } catch {
      line.textContent = "This browser would not copy. Show it and copy it by hand.";
    }
  } } }, "Copy");
  return h("div", { class: "card" },
    h("h3", {}, card.title),
    h("p", { class: "small" }, card.asset ? `${card.asset} · ${CARD_LABELS[card.cardType]}` : CARD_LABELS[card.cardType]),
    value,
    card.note ? h("p", { class: "dim" }, card.note) : null,
    h("p", {}, showBtn, copyBtn),
    line,
  );
}

async function envelopes(ck, me, kems, j, now) {
  working("Opening your envelopes…");
  const opened = await openEstate(ck, j, kems, now);
  if (!opened.length) {
    problem("The release is real, but no envelope here opens with your key. If you were given a new key, the writer may need to seal again.");
    return;
  }
  const nodes = [h("p", { class: "lede" }, `From ${j.ownerName || "someone"}, released ${dateLine(j.snapshot.releasedAt)}.`)];
  for (const { entry, payload } of opened) {
    const held = payload.openNoEarlierThanEpoch !== null && now < payload.openNoEarlierThanEpoch;
    const parts = [h("h2", {}, payload.title || "An envelope")];
    if (held) {
      parts.push(h("p", {}, `${j.ownerName || "The writer"} asked that this one stay closed until ${dateLine(payload.openNoEarlierThanEpoch)}. This page keeps it closed until then.`));
    } else {
      if (payload.letter.trim()) parts.push(h("div", { class: "letter" }, payload.letter));
      if (payload.voiceNote) parts.push(mediaBlock(ck, j, entry, payload.voiceNote, "Play the voice message"));
      if (payload.videoNote) parts.push(mediaBlock(ck, j, entry, payload.videoNote, "Play the video"));
      payload.photos.forEach((p, i) => parts.push(mediaBlock(ck, j, entry, p, payload.photos.length > 1 ? `Show photo ${i + 1}` : "Show the photo")));
      const steps = (payload.firstSteps ?? []).filter((s) => s.title.trim() || s.note.trim());
      if (steps.length) {
        parts.push(h("h3", {}, "What to do first"));
        parts.push(h("ol", { class: "plain" }, steps.map((s) => h("li", {}, h("b", {}, s.title), s.note ? h("span", { class: "dim" }, ` ${s.note}`) : null))));
      }
      if (payload.secrets.length) {
        parts.push(h("h3", {}, "Secrets"));
        for (const card of payload.secrets) parts.push(secretBlock(card));
      }
      for (const f of payload.files ?? []) parts.push(mediaBlock(ck, j, entry, f, `Get ${f.fileName || "the file"}`));
    }
    nodes.push(h("section", { class: "envelope" }, parts));
  }
  nodes.push(h("p", { class: "small" }, "Nothing is saved in this browser. When you are done, close the tab."));
  show(...nodes);
}

start();
