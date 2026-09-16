# Deploying the CloudKit schema to Production

**Date:** 2026-09-15 (EstateEvent added) · Container `iCloud.io.github.jasonepage.Seal` · Team `8C4BM6A82T`

## What this actually is

"Deploy schema" copies **record types, fields and indexes** from the Development
environment to the Production environment. It copies **zero records**. It is not
deploying your app and it does not move any data.

It matters because **TestFlight and App Store builds only ever talk to
Production, and Xcode builds only ever talk to Development.** They are two
separate worlds with separate data. Anything you added in Development is
invisible to a TestFlight build until you deploy.

It is **additive only**. Once a field exists in Production you cannot delete it,
so read the pending list before you click the button.

## Part A: make sure Development has everything first

The deploy copies whatever Development has, so Development has to be right.

1. Run the app from Xcode onto your phone. Xcode builds always hit Development.
2. Go to You → Your keys → **Add a backup key**, and do it once.
   That write creates the `backupEndorsements` field on `Identity`
   automatically. If you get the "backup keys aren't switched on in this
   environment" message instead, the field was not created and you add it by
   hand in step 4.
3. Open <https://icloud.developer.apple.com/>, choose **CloudKit Database**, pick
   the container at the top, and make sure the environment selector says
   **Development**.
4. Schema → Record Types → `Identity`. Confirm these fields exist, all type
   **Bytes**, and add any that are missing:
   - `backupEndorsements`
   - `revocations`
   - `perks`

   Do **not** mark any of them queryable, sortable or searchable. Nothing
   queries on them and an index on a blob costs for nothing.
5. Schema → Record Types. Confirm `EstateEvent` exists with fields `estate`
   (String), `kind` (String), `actor` (String) and `payload` (Bytes). It is
   created automatically the first time an Xcode build seals an estate
   (Development has just-in-time schema); if it is missing, add it by hand.
   `PerkGrant` and `PerkClaim` are retired and can stay or go; nothing reads
   them.
6. Schema → Indexes → `EstateEvent`. `estate` needs a **QUERYABLE** index.
   Without it custodian phones cannot find an estate's events at all and the
   failure is silent. `recordName` on `EstateEvent` needs nothing.
7. Schema → Indexes → `GroupInvite`. `recipient` needs a **QUERYABLE** index:
   `fetchEstateInvites` and the invite push subscription both query on it.
   Since 2026-09-16 device and backup key revocations are ALSO published as
   `GroupInvite` records (`recipient` = `revoke.<identity hash>`, random
   record name), and every directory lookup queries for them. No new record
   type and no new field, but without this index revoking a phone and
   looking anybody up both fail.
8. Schema → Indexes → `Identity`. Confirm `recordName` has a **QUERYABLE**
   index. **This is the one that matters most.** Without it the directory scan,
   the one-key-one-identity check and security-key sign-in all break in
   TestFlight, and they break quietly.

## Part B: deploy

Apple's own steps, from
<https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema>:

1. Sign in at <https://icloud.developer.apple.com/>.
2. Select the **CloudKit Database** app.
3. In the top section, choose the container from the list.
4. On the left, select **Deploy Schema Changes**.
5. Review the pending changes and click **Deploy**.

You need edit privileges on Production. As an individual account holder you are
the team administrator, so you already have them.

## Part C: prove it landed

Install a TestFlight build and sign in once with a backup credential, end to
end. A non-discoverable backup key is only tappable if the scan returns its ID,
so this is the check that the allow-list path actually works in Production
rather than only in Development.

## If something looks wrong afterwards

Reset Environment (left sidebar, Development only) wipes all records in
Development. If your schema is already in Production, resetting reverts the
Development schema to match Production rather than deleting record types. It
never touches Production data.
