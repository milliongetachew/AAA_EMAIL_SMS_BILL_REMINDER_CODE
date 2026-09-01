# MOVEit / AFT Delivery Pipeline Reference (Real Job Configuration)

Source: screenshots of the actual Control-M/AFT ("Advanced File Transfer")
job definitions and three real sample output files, supplied by the user
2026-09-01. This corrects and sharpens the file-delivery design in
`high-level-design.md` §4 and the placeholder upload logic in
`NotificationGatewayService.cls`.

## Headline correction: MOVEit is a relay, not the final destination

The delivery pipeline is **two stages**, chained by job predecessor, not the
single "generate file → MOVEit → done" model assumed earlier:

1. **Stage 1 — mainframe write-to-staging ("O" job).** An AFT job (e.g.
   `MRD1104O_AFT_PUSH_MEM_ZEROAUTH`) transfers a mainframe dataset from `MP`
   (`FTP-ZSYS`, host `CTMP01`) to a **local staging path** on `DP` (a local
   server, `gid01943`) under `%%PGPTemp.\MRD\...`. This file is **plaintext**
   at this point.
2. **Stage 2 — encrypt + transfer to MOVEit ("E" job).** A separate
   "Encrypted File Transfer Job" (e.g. `MRD1104E_AFT_PUSH_MEM_ZEROAUTH`,
   `Required Predecessor` = the Stage 1 job) runs under host group `AFT_PGP`,
   AFT account `PGPNT+MOVEIT`. It PGP-encrypts the Stage 1 staging file
   **client-side, before it ever reaches MOVEit**, using a named CTM PGP
   template, then transfers the encrypted file to MOVEit as Binary and
   **deletes the plaintext source** after a successful transfer.

**MOVEit itself is therefore the relay endpoint of Stage 2, not the final
consumer.** The observed PGP key is explicitly bound to Salesforce:

| Field | Value |
|---|---|
| CTM PGP Template Name | `PUB_SalesForce` |
| PGP Key Name | `salesforce-prod-042325-1 (sfmc xfer)` |
| Vendor | `SalesForce` |
| Key Valid Until | `09/09/2026` |
| Destination Path | `/users/SMSPUSH/OUTBOUND/` (relative to the MOVEit server's home directory `\\sa0mvitcen120\users\`, which must NOT be included in the path) |
| Destination filename | source filename + `.pgp` appended automatically |

The `(sfmc xfer)` annotation on the key name, combined with the real SMS
output column `SubscriberKey`/`Locale` (SFMC MobileConnect-specific
terminology — see below), makes it near-certain the **actual final
destination past MOVEit is Salesforce Marketing Cloud** (most likely via
SFMC's own inbound file pickup / Automation Studio File Transfer Activity
importing into a Data Extension), not a generic third-party SMS/email
vendor. This should be treated as strongly indicated, not 100% confirmed —
worth a direct confirmation with whoever owns the SFMC side.

**Design implication for `NotificationGatewayService`:** the Salesforce Core
(Revenue Cloud) side of this migration does not need to implement PGP
encryption OR speak MOVEit's transfer protocol directly. The realistic
implementation is to plug into the **same existing two-stage AFT/MOVEit
pipeline** — i.e. have the new Apex-generated extract land wherever Stage 1
currently drops its plaintext staging file (or an equivalent new drop point
the AFT/integration team provisions for Salesforce-originated files), and
let the existing Stage 2 encrypt+transfer job carry it the rest of the way.
**Open question, not yet resolved:** Salesforce Apex can only make outbound
HTTPS callouts — it cannot write to a Windows/mainframe-local file share
like the `gid01943` staging server directly. Whether Salesforce hands off
via an HTTPS endpoint the AFT/integration layer exposes, or a different
mechanism entirely, needs confirmation from the AFT/MOVEit/integration team
before implementation — do not assume either shape as fact.

## Naming conventions observed

- **Mainframe dataset**: `MRDPN.<PROGRAM>.<TYPE>.<VARIANT>(0)`, e.g.
  `MRDPN.MD021.PUSH.NOTIFY(0)`, `MRDPN.MD022.PUSH.EARLY(0)`,
  `MRDPN.MD022.SMS.INT77(0)`, `MRDPN.MD022.PUSH.INT77(0)`.
- **Local staging file** (`%%PGPTemp.\MRD\...`), by program/variant:
  - `MD021` renewal push/SMS notify → `Mem_Payment_Push_NotifyYYYYMMDD.csv`
  - `MD022` PUSH EARLY (45-day alert) → `EMembershipPUSHAlert45Day_%%Year%%%%Month%%%%Day%%.txt` (**`.txt`, not `.csv`**)
  - `MD022` SMS INT77 (the −77-day window — this is the real-world identity of `MD022ZA`'s previously-unresolved "-77 day" eligibility window flagged in the HLD) → `TRAN_SMS_MEM_ZEROAUTH_MINUS_77DAYS_%%$DATE..csv`
  - `MD022` PUSH INT77 (same −77-day window, Push channel) → `TRAN_PUSH_MEM_ZEROAUTH_MINUS_77DAYS_%%$DATE..csv`
- **AFT/CTM job pair naming**: `MRD<job-number><O|E>_AFT_<TYPE>_<NAME>` —
  `O` = write-to-staging job, `E` = encrypt-and-transfer job, linked via
  `Required Predecessor`.
- **MOVEit destination path convention**: `/users/<QUEUE_NAME>/OUTBOUND/` —
  only `SMSPUSH` was observed directly; other channels (email, CAU) likely
  follow the same `/users/<QUEUE>/OUTBOUND/` pattern with a different queue
  name, but this is inferred, not confirmed — do not hardcode other queue
  names without verifying them the same way.

## Real output file layouts (from sample files, not the AFT screenshots)

These are the **actual current column layouts**, and should replace any
earlier illustrative/guessed CSV shape in `NotificationGatewayService`'s
`buildFileBody()` for the corresponding programs. Column order matters if
the downstream SFMC import is positional rather than header-mapped —
confirm before assuming header-based mapping is safe to rely on.

**SMS / Push extract** (`SMS - latest.xlsx`, 646 sample rows) — 9 columns:

```
SubscriberKey, MobileNumber, Locale, CustId, ClubCode, Membership#, ExpirationDt, FirstName, Zipcode
```

`SubscriberKey` and `Locale` (`en-US` on every sampled row) are Salesforce
Marketing Cloud **MobileConnect** terminology specifically — further
evidence the final consumer is SFMC. In the sample, `SubscriberKey` equals
`CustId` on every row (both hold the same 15-digit legacy customer id).

**Email extract** (`EMAIL- latest.xlsx`, 3,787 sample rows) — 11 columns:

```
EmailAddress, CustID, ClubCode, State, FirstName, LastName, Membership Level, CellName, Zip, MembershipNumber, ExpirationDate
```

`CellName` here is almost certainly an SFMC/Email-Studio "cell" (segment)
identifier, not a phone field — confirm before assuming otherwise. Every
sampled row was club `001`, state `AL`.

**CAU email test file** (`CAU EMAIL Test file v2`, plain text,
semicolon-delimited with each field **space-padded to a fixed width before
the delimiter** — a hybrid fixed-width/delimited format, matching
`MD058CB`'s legacy record layout) — 8 columns:

```
EmailAddress;CustId;ClubCode;FirstName;Zipcode;MembershipNumber;ExpirationDate;Last4Digits
```

Rows with a blank `EmailAddress` (padded-blank field before the first `;`)
appear in the sample alongside a `CustId` in the legacy
`000NNNNNN999901`-style format — worth carrying forward the same "blank
email is valid, still emit the row" behavior rather than filtering it out,
unless the business says otherwise.

## What this changes in the Apex scaffold

- `NotificationGatewayService.uploadChannelFile()`'s destination (currently
  a placeholder `MOVEIT_UPLOAD_PATH`) should be reconsidered against the
  two-stage model above — it is very unlikely Salesforce can call a MOVEit
  REST endpoint carrying a raw plaintext file the way the current scaffold
  assumes, since real PGP encryption happens in a separate Stage 2 job
  *before* MOVEit is even involved. This needs a real answer from the
  AFT/integration team, not a corrected guess.
- `DELIMITER_BY_PROGRAM`'s file-format table should be replaced with the
  real per-channel layouts above for the programs sampled here
  (SMS/Push, Email, CAU-email); the fixed-width `MD022*`/`MD058CB` gap
  noted in the class remains for any layout not covered by these three
  samples.
