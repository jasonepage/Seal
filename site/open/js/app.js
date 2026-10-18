// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  app.js
//
//  The recipient page (PRODUCT.md section 15, 1.2a). Read only. Two taps
//  of the security key someone registered for this person: the first says
//  which key it is, the second hands over the key's secret (WebAuthn PRF)
//  that unlocks this person's private keys, in memory only. Then the page
//  finds the envelopes written to them, judges each release the way the
//  phone does, and opens only what was released.
//
//  Everything the writer wrote is shown with textContent, never as HTML.
//  Nothing is written to browser storage. Closing the tab forgets it all.

import { config } from "./config.js";
import { toHex, sha256, same } from "./bytes.js";
import { CloudKit, bytesField, stringField } from "./cloudkit.js";
import { unlockSponsored } from "./crypto.js";
import { fetchIdentity, findInvites, judgeEstate, openEstate, openMedia } from "./estate.js";
import { verifiedDevices } from "./identity.js";
import { phrase } from "./words.js";

const main = document.getElementById("app");

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
    h("p", { class: "lede" }, "If someone gave you a security key for Seal, it opens the envelopes they wrote to you, once they are released."),
    h("ol", { class: "steps" },
      h("li", {}, h("span", { class: "n" }, "1"), h("b", {}, "Have your key ready. "), "Plug it in, or hold it to your phone when asked. If it has a PIN, you will need it."),
      h("li", {}, h("span", { class: "n" }, "2"), h("b", {}, "Tap it twice. "), "The first tap says which key it is. The second unlocks your envelopes on this page."),
      h("li", {}, h("span", { class: "n" }, "3"), h("b", {}, "Read, then close the tab. "), "Nothing is saved in this browser. Closing the tab forgets everything."),
    ),
    h("button", { class: "cta", type: "button", on: { click: () => run().catch(failed) } }, "Use my security key"),
  );
}

function failed(err) {
  if (err?.name === "NotAllowedError") return problem("The key was not tapped, or the request was cancelled. Nothing was opened.");
  if (err?.name === "SecurityError") return problem("This page has to be opened at sealmessenger.com for your key to answer.", false);
  problem(err?.message || "Something went wrong. Nothing was opened.");
}

// ---------------------------------------------------------------- the taps

async function credentialIDs(ck) {
  const records = await ck.query("Identity", null, null, { desiredKeys: ["credentialID", "tier"], maxPages: 50 });
  const ids = [];
  for (const r of records) {
    if (r.recordName.startsWith("tomb.") || stringField(r, "tier") !== "verified") continue;
    const id = bytesField(r, "credentialID");
    if (id) ids.push(id);
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
  const ids = await credentialIDs(ck);
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
    throw new Error("This key belongs to someone who uses the Seal app. Open your envelopes there. The browser page is for keys that were registered for you by someone else.");
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

  working("Finding envelopes written to you…");
  const invites = (await findInvites(ck, myHash, kems)).filter((i) => i.role === "recipient");
  if (!invites.length) {
    show(h("p", { class: "lede" }, `Signed in as ${me.root.displayName}.`), h("p", {}, "Nobody has written envelopes to you yet, or the writer has not sealed them. Check again later."));
    return;
  }
  const now = nowSeconds();
  const judged = [];
  for (const invite of invites) {
    working(`Checking the record for ${invite.ownerName || "a writer"}…`);
    judged.push(await judgeEstate(ck, invite, now));
  }
  await list(ck, me, kems, judged, now);
}

// ---------------------------------------------------------------- the list

function stateLine(j, now) {
  if (j.problem === "owner") return "The writer's record could not be checked, so nothing here is opened.";
  if (!j.openingAllowed) return "The writer cancelled these envelopes when they deleted their Seal account. They can never be opened.";
  switch (j.state) {
    case "released": return "Released. You can open them.";
    case "warning":
    case "grace": return `Not open yet. A key holder started the release, and the writer is being warned${j.timeline ? `. The earliest they could open is ${dateLine(j.timeline.claimOpensAt)}` : ""}.`;
    case "claimOpen":
    case "authorized": return "Not open yet. The key holders are being asked to tap their keys.";
    case "objected": return "Not open yet. A key holder objected, so the release is on hold.";
    default: return "Still sealed. They open only if the writer goes quiet for a long time and their key holders agree.";
  }
}

async function list(ck, me, kems, judged, now) {
  const items = [];
  for (const j of judged) {
    const owner = await fetchIdentity(ck, j.ownerHash, { history: true }).catch(() => null);
    const words = owner ? await phrase(owner.root.publicKey) : null;
    const open = j.state === "released" && j.openingAllowed;
    items.push(h("div", { class: "card" },
      h("h3", {}, `From ${j.ownerName || "someone"}`),
      words ? h("p", { class: "small" }, `Their words: ${words}. In the app these show under their seal as "Your words". If you know theirs, check they match.`) : null,
      h("p", {}, stateLine(j, now)),
      open ? h("button", { class: "cta", type: "button", on: { click: () => envelopes(ck, me, kems, j, now).catch(failed) } }, "Open") : null,
    ));
  }
  show(
    h("p", { class: "lede" }, `Signed in as ${me.root.displayName}.`),
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
