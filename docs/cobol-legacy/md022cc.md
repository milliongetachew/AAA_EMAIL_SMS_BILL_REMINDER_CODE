# MD022CC

Source: `attachments/md022cc.txt` (PROGRAM-ID coded in lowercase as `md022cc`)

## Summary

MD022CC generates SMS and Push extract files for members whose next
billing event is a credit-card decline (`FK_MBR_BILL_EVENT = '75'`),
excluding club `'065'`. As of its most recent change it sends both SMS
and Push notifications to any member with a valid cell phone on file,
with **no SMS opt-in/consent check** — the consent check that exists in
its sibling programs was explicitly removed here.

## Inputs and Outputs

- **Output files**: `SMS-FILE` (DD `OSMSFILE`, PIC X(120)) and
  `PUSH-FILE` (DD `OPSHFILE`, PIC X(120)).
- **Runtime parameter**: `WS-INTERVAL-DAYS` via `ACCEPT ... FROM SYSIN`.
- **DB2 tables**: `MBRSHP_HOUSEHOLD`, `MBRSHP_NEXT_EVENT`, `MBR_INFO`/
  `MEMBER`, `SQLCA`.
- **Cursor `csr-cc-decline`**: joins household, next-event, and
  member-info where `NE.NEXT_EVENT_D = :WS-TARGET-DATE`, role `'00'`,
  currently effective, `FK_MBR_BILL_EVENT = '75'` (credit card decline
  event), and club `<> '065'`.
- **External subprograms**: `MD930BR` (processing date), `MC501BCD`
  (customer data/phone). `MC556BR` (consent) is declared and its calling
  paragraph (`7100-CHECK-CONSENT`) still exists in source but is
  entirely commented out (see MEM-482325 below) and never executed.
  `MCFCCAUT`, `MD999CK`, `MD610BR`, `MD699BR`, `FN435BT` are declared but
  unused.
- **Copybooks**: `MD022SP` (shared SMS+Push record layout, same as
  `MD022LP`/`MD022ZA`), `MRD930C`, `MAC501C`, `MAC556C`, `MAC900C`,
  `MRD900C`, `MRD901C`, `MRD903C`.

## Key Data Structures

Identical shape to `MD022LP`: `WS-SMS-PUSH-REC-AREAS` (copybook
`MD022SP`), `WS-CUST-ID` (packed customer id), `WS-PHONE-NUMBER`
(area/prefix/suffix), `WS-TARGET-DATE` computed as
`(PROC-DATE-ISO − WS-INTER-DAYS DAYS) + 1 YEAR` (same formula family as
`MD022EC`/`MD022LP`).

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens both output files, gets processing
   date, computes target date, opens the `csr-cc-decline` cursor, writes
   header rows to both files. Also displays explicit start/end banner
   messages (`M D 0 2 2 C C --- S T A R T E D` / `ENDED`) not present in
   the sibling programs.
2. **2000-PROCESS-CURSOR** loops per fetched row until SQLCODE 100; for
   each non-blank club/customer id row, performs
   **3000-GENERATE-SMS-PUSH** and increments the extract counter.
3. **3000-GENERATE-SMS-PUSH**:
   - **7000-CALL-MC501BCD**: fetches first name and qualifying cell
     phone.
   - If a phone number was found, **4000-WRITE-SMS-RECORD** writes the
     SMS detail record directly — **no consent check is performed**
     (the call to `7100-CHECK-CONSENT` and the `IF MEMBER-CONSENT-YES`
     gate that would have wrapped this write are both commented out
     under MEM-482325).
   - **5000-WRITE-PUSH-RECORD** is always performed regardless of phone
     presence (unlike the SMS write, which requires a phone number).
4. **9999-FINAL-RTN**: closes the cursor and displays extracted/SMS-
   written/Push-written counts.

## Modification History

| Date | Ticket | Description | By |
|---|---|---|---|
| 08/23/2024 | MEM-479718 | Add first name to SMS and Push file | Rathna R |
| 05/15/2025 | MEM-482325 | Remove opt-in (SMS consent) criteria — the `MC556BR` consent check that previously gated the SMS write was disabled | Praveena |

## Ambiguous / Environment-Dependent Notes

- Same `(− interval + 1 YEAR)` target-date formula ambiguity noted in
  `MD022EC`/`MD022LP` applies here.
- The removal of the consent check (MEM-482325) is a deliberate, recent
  business decision reflected faithfully in the code — worth calling out
  explicitly to anyone porting this logic, since it is a meaningful
  compliance-relevant difference from the sibling programs that still
  gate SMS on consent.
- `5000-WRITE-PUSH-RECORD` is called even when `MC501BCD` returns no
  phone number at all (it is outside the `IF WS-PHONE-NUMBER > ZEROES`
  block) — worth confirming this always-write-push behavior is
  intentional versus the phone-gated write pattern used elsewhere.
- Program name literal used when calling `MC501BCD` is `'MD022CC '`
  (uppercase in the literal despite the lowercase `PROGRAM-ID`).
