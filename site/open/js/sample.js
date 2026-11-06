// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  sample.js
//
// A sample letter for people who have no key yet (sealmessenger.com/open/#sample).
//
// Nothing here is encrypted, fetched or real. It is plain data the page shows
// through the same reveal a real letter gets, so a visitor can see what
// opening one looks like before they write one. It never touches a key,
// CloudKit or the release rules, and it says it is a sample on every screen.
// The case is the right away use PRODUCT.md section 17 names: a house
// sitter's key that opens the alarm code and the Wi-Fi.

export const SAMPLE = Object.freeze({
  from: "Harbor",
  title: "For the house sitter",
  letter: [
    "Hi! Thanks for watching the house this week.",
    "",
    "This is a sample letter, so nothing in it is real. A real one looks just like this, and it can also hold a video, a voice message and photos.",
    "",
    "Nobody could read it before you opened it. Not Apple, not Seal, not whoever handed you the key. Only that key opens it.",
    "",
    "Harbor",
  ].join("\n"),
  photo: { src: "../harbor-home.png?v=1", alt: "Harbor, the Seal mascot, a gray seal with a gold collar.", caption: "Photos open here too." },
  steps: [
    { title: "Feed the cat at 7 and at 5.", note: "Half a scoop each time." },
    { title: "Water the tomatoes on Sunday.", note: "" },
  ],
  secrets: [
    { title: "Alarm code", cardType: "combination", value: "4815 92", note: "Sample only. Not a real code." },
    { title: "Wi-Fi", cardType: "password", value: "harbor-guest / not-a-real-password", note: "" },
  ],
});
