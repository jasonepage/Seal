Privacy Policy
Last updated: September 16, 2026

Seal holds the things people cannot afford to have read early. So this policy is written to be checked rather than trusted, and it says what leaks as plainly as it says what does not.

What we can never see
Your letters, photos, voice messages, videos and secrets are encrypted on your phone before they leave it. The keys that open them stay on your devices and are never sent to us. Seal has no server of its own and no way to decrypt anything. There is no password and no email or text reset. If you lose your key, only a backup key you registered earlier can bring your identity back. Nobody else can, including us and Apple.

That is a statement about what is technically possible, not a promise about our intentions. We could not hand over an envelope if asked, because we hold nothing that would open one.

One exception to "keys stay on your devices": if you register a security key for someone who is not on Seal yet, that person's private keys are stored in iCloud, locked with a secret that only their physical security key can produce. Without that key, the stored copy cannot be opened.

What is stored, and where
Seal uses Apple's iCloud (CloudKit) as a filing cabinet, under our developer account. It holds:

* Your public identity record: the display name you chose, your public keys, an account ID made from your key, and which kind of key you use. This is public on purpose, so the people you meet can check it is you.
* Encrypted envelope contents, which cannot be read.
* A signed record of what happened and when: an envelope set was created, a rule was set, you checked in, a key holder started a claim or stopped one. Each entry is signed. The entries themselves are not encrypted: they show what kind of event it was, who made it (as an account ID), and when. Your rule and the list of your key holders' account IDs are in this record, so your key holders can check each other. If a key holder types a reason when starting a claim, or a note when objecting, that text is stored as written.
* Invitations, encrypted and addressed by a one way fingerprint of the person invited.
* Device and key revocations you sign, so other phones stop trusting a device you removed.

What the record shows, stated plainly
Perfect hiding is not one of the promises. Someone who could read the stored data could work out:

* Who your key holders are, by account ID, and your rule.
* When you check in, and when a claim starts or stops.
* How many people you wrote envelopes to, and roughly how much you wrote.
* That a particular account has some part in some envelope set.

What they could not work out: the titles, the letters, the photos, the secrets, or who any envelope is for.

Help writing, which never leaves the phone
Seal can ask you questions and turn your answers into a draft, and it can turn your speech into text. Both run entirely on your phone. Nothing you write or say there is sent to us, to Apple, or to anyone else. If a phone cannot do this work on its own, Seal does not offer it on that phone.

The one service outside Apple
Seal asks a public timestamp service, currently freetsa.org, to sign the time of important record entries: check-ins, claims, stops, key taps and releases. This happens automatically whenever you have an envelope set, because those times are what protect you and your family. For other activity, timestamps are off until you turn them on.

Seal sends only a short one way fingerprint (a hash) of the entry. It cannot be turned back into your envelope, your name or anything you wrote. What it does tell that service is that something was recorded, and when, along with the network address it came from.

Notifications
Seal uses Apple's push service so the people who hold a key hear about a claim, and so a person knows when they have been given a part in someone's plan. The alert text is fixed in the app and carries nothing about the contents of anything.

What we collect about you
Only what is listed above: your display name, your account ID, your check-in times, and any claim reasons or objection notes. We use them only to make Seal work. Seal has no analytics, no trackers, no advertising identifiers, no crash reporting service and no third party code that phones home. We never ask for your phone number, email address, contacts or location. Purchases are handled by Apple, and we do not receive your payment details.

Reports
If you report somebody, the report goes from your own mail app to our support address and includes the account IDs involved. We act on valid reports within 24 hours. Removing somebody from your People list is stored only on your phone.

Deleting your identity
Open your profile (the round name badge at the top left), then tap Delete identity. Your record is permanently marked as deleted and the app wipes its data on that phone. This cannot be undone, by you or by us, because deletion is enforced by a write once marker rather than a flag we could flip back. People who met you will see that your account was deleted.

Anything already delivered to another person's phone stays on that phone, like a letter you already handed over.

Children
Seal is not meant for anyone under 18. It is for planning what happens to your belongings and accounts, and an identity is tied to a passkey or security key belonging to one person.

Changes and contact
The current version of this policy is always at this address, with its date updated. Questions: support@sealmessenger.com
