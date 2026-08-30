# MD022ER

Source: `attachments/M D 0 2 2 E R.txt`

## Summary

MD022ER is a DB2-cursor-driven variant of `MD022EX` that was built to
produce an "early" push/SMS extract — i.e. reminders sent well before the
standard renewal-due notice — for members in renewal, not on autopay,
with an unpaid balance and no payment in transit. Unlike `MD022EX` it
writes to **two separate output files** (SMS and Push) rather than one,
using a shared record layout that carries a message-type flag. The SMS
file still requires text-messaging consent; the Push file is written
whenever a cell number and an amount due exist, regardless of SMS
consent.

## Inputs and Outputs

- **Output files**: `SMS-FILE` (DD `MD022OP`, PIC X(300)) and
  `PUSH-FILE` (DD `MD022PSH`, PIC X(300)); both use header row
  `WS-HEADER` (ExtractDate; MessageType; CustID; EmailAddress;
  SubcriberKey; ClubCode; FirstName; LastName; ExpirationDate;
  AmountDue; MembershipNumber; Locale; MobileNumber;).
- No file-based date input in this variant — the processing date comes
  from `MD930BR` (a callable date-service subroutine), not a `DATE-FILE`.
- **DB2 tables**: `MBRSHP_HOUSEHOLD`, `MBR_PRD_DTL`, `MBR_INFO`/`MEMBER`,
  `SQLCA`.
- **Cursor `CUSTID`**: identical join/filter shape to `MD022EX`'s cursor
  (`CUR_TERM_EXP_D < REN_TERM_EXP_D`, `FK_BILL_PLAN_TYP_C = 'AM'`, unpaid,
  `EFF_D = :TARGET-DATE`), also selecting `CUR_TERM_EXP_D`.
- **External subprograms**: `MD930BR` (get batch processing date),
  `MD999CK`, `MD610BR` (amount due), `MD699BR` (business-rule SMS/push
  day offset, club `'001'` hard-coded — same limitation as `MD022EX`),
  `MC501BCD`, `MC556BR` (consent), `FN435BT` (declared but note: PIT
  check is **not actually gating** the extract in this version — see
  Control Flow).
- **Copybooks**: `MAC501C`, `MAC556C`, `MAC900C`, `MRD610C`, `MRD960C`,
  `MRDR23C`, `MRD022C1` (expanded record with SMS/Push type discriminator,
  replacing the plain `MRD022C` used by `MD022EX`), `MRD900C`,
  `MRD901C`, `MRD903C`, `MRD930C` (MD930BR linkage), `MRD999CK`,
  `FIN435C`.

## Key Data Structures

- `WS-SMS-RECORD` (copybook `MRD022C1`): the shared SMS/Push record
  layout; `SET SMS-FILE-TYPE TO TRUE` / `SET PUSH-FILE-TYPE TO TRUE`
  toggle a level-88 condition on `MD022-MESSAGE-TYPE` before each write,
  so the same working-storage record is written to whichever file is
  currently being produced.
- `MD930-LINK-DATA` (copybook `MRD930C`): linkage for the callable
  processing-date service (`MD930-ISO-DT`, `MD930-PROC-DATE`).
- `MD23-INPUT-OUTPUT-RECORD` / `SMS-DAYS`: as in `MD022EX`, business-rule
  driven number of days added to the processing date to compute
  `TARGET-DATE`.
- `MD610-LINK-DATA`: amount-due lookup; `MD610-TOTAL-DUE` populates
  `DUES`/`MD022-AMOUNT-DUE`.
- `MC556-INPUT-OUTPUT`: SMS consent check output
  (`MC556-O-AUTHORIZED-FLAG`).
- Commented-out `WS-SEND-SMS-PUSH-SW` / `WS-WILDFIRE-ZIP` fields — same
  dead wildfire-suppression logic seen in `MD022EX` (MEM-480330,
  reverted by MEM-480960).

## Control Flow

1. **A0000-INITIALIZE-ROUTINE**: opens both output files; gets the
   processing date from `MD930BR` (A1000); gets the SMS/push day offset
   from `MD699BR` for club `'001'` (A2000); computes `TARGET-DATE =
   PROC-DATE-ISO + SMS-DAYS` (A3000); opens the cursor and performs the
   first fetch — if the cursor is immediately empty, the program abends;
   writes the header row to both output files.
2. **B0000-PROCESS-CURSOR** loops per fetched row until end of cursor:
   - Builds the semicolon-delimited record shell (extract date,
     expiration date, customer id, club code, locale `en-US`); message
     type is now set later, per-file, rather than fixed to `SMS`
     (MEM-475586 change).
   - Calls `MD999CK` for the 16-digit membership number.
   - Calls **S1000-CHECK-PIT** (`FN435BT`) — **note:** unlike `MD022EX`,
     the PIT result here does not gate `B1000-PROCESS-SMS-PUSH`; the
     result is computed but `B0000` unconditionally performs
     `B1000-PROCESS-SMS-PUSH` for every fetched row regardless of the PIT
     flag (see Ambiguity note — this differs from the sibling programs
     and may be intentional or a latent gap).
   - **B1000-PROCESS-SMS-PUSH**: calls `MC501BCD` for name and cell
     phone. If a cell number exists:
     - Calls **S3000-CHECK-CONSENT** (`MC556BR`).
     - Calls **S4000-AMOUNT-DUE** (`MD610BR`); if an amount is due:
       - If SMS-consented, writes the SMS record
         (`W0000-WRITE-OUTFILE`); if not consented, the row is only
         counted as skipped/no-consent for the SMS side.
       - **Always** writes the Push record (`W1000-WRITE-PUSH-FILE`),
         regardless of SMS consent — Push notifications do not require
         the same opt-in as SMS in this program.
     - If no amount is due, the row is skipped entirely (no SMS, no
       Push) and counted.
     - If no cell phone is found, the row is skipped and counted.
3. **Z0000-EOF-ROUTINE**: displays input/skipped/PIT/no-cell/no-consent/
   no-amount/SMS-written/Push-written counts and closes both files.

## Modification History

| Date | Who | Description |
|---|---|---|
| 09/01/20 | sfavrin | MEM-475418 — new program cloned from MD022EX |
| 09/01/20 | sfavrin | MEM-475586 — add 45-push file (second output file) |
| 11/10/20 | sfavrin | MEM-475586 — set message types based on which file is being written, rather than a fixed literal |
| 01/16/25 | Kumar | MEM-480330 — added CA wildfire zip-code SMS/Push suppression |
| 06/11/25 | Praveena | MEM-480960 — removed the MEM-480330 wildfire changes |

## Ambiguous / Environment-Dependent Notes

- The payment-in-transit (PIT) check (`S1000-CHECK-PIT`,
  `FN435BT`) is performed for every row but its result
  (`MEMBER-HAS-PIT-YES`/`NO`) is **not referenced anywhere** in
  `B0000-PROCESS-CURSOR` to gate processing — unlike `MD021EX`/`MD022EX`
  where a PIT member is explicitly skipped. This could be an intentional
  design choice for this "early" extract (e.g., PIT doesn't matter this
  far ahead of the due date) or an oversight carried through cloning;
  flagging rather than assuming either way.
- Same club-`'001'`-for-all-clubs business-rule shortcut as `MD022EX`
  applies here for the SMS/push day offset.
- Output DD names `MD022OP` / `MD022PSH` consumers are external
  (presumably an SMS gateway and a mobile push gateway respectively).
