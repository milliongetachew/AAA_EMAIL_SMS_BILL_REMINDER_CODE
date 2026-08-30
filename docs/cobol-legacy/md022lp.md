# MD022LP

Source: `attachments/MD022LP.txt`

## Summary

MD022LP generates SMS and Push notification extract files for members
who are in specific "late pay" billing events at their renewal term
expiration date (an interval-based target date, computed the same way as
`MD022EC`). It is a general (non campaign-code-restricted) late-payment
reminder: any club, any qualifying billing event, is eligible, unlike
`MD022EC` which is scoped to particular marketing campaigns.

## Inputs and Outputs

- **Output files**: `SMS-FILE` (DD `OSMSFILE`, PIC X(120)) and
  `PUSH-FILE` (DD `OPSHFILE`, PIC X(120)), each with a header record plus
  one detail record per notified member.
- **Runtime parameter**: `WS-INTERVAL-DAYS` via `ACCEPT ... FROM SYSIN`.
- **DB2 tables**: `MBRSHP_HOUSEHOLD`, `MBRSHP_NEXT_EVENT`, `MBR_INFO`/
  `MEMBER`, `SQLCA`.
- **Cursor `LATEPAY`**: household + next-event + member-info join where
  `REN_TERM_EXP_D = :WS-TARGET-DATE`, role `'00'`, currently effective,
  `FK_MBR_BILL_EVENT IN ('04','40','41','55','56','57','58','59')`,
  excluding bill-plan types `'AC'`/`'AH'` and bill cycles
  `'IM'`/`'MA'`/`'NB'` — the same billing-event filter as `MD022EC` but
  **without** the campaign-code/club restriction.
- **External subprograms**: `MD930BR` (processing date), `MC501BCD`
  (customer data/phone), `MC556BR` (SMS consent). `MCFCCAUT`, `MD999CK`,
  `MD610BR`, `MD699BR`, `FN435BT` are declared but unused (same pattern
  as `MD022EC`).
- **Copybooks**: `MD022SP` (shared SMS+Push header/detail record layout,
  also used by `md022cc` and `MD022ZA`), `MRD930C`, `MAC501C`, `MAC556C`,
  `MAC900C`, `MRD900C`, `MRD901C`, `MRD903C`.

## Key Data Structures

- `WS-SMS-PUSH-REC-AREAS` (copybook `MD022SP`): shared record group with
  distinct SMS header/detail (`WS-SMS-HEADER-RECORD`,
  `WS-SMS-DETAIL-RECORD`) and Push header/detail
  (`WS-PUSH-HEADER-RECORD`, `WS-PUSH-DETAIL-RECORD`) areas — each detail
  record carries subscriber key, customer id, club code, extract date,
  locale, first name, and (Push only) a message-type literal `'PUSH'`.
- `WS-CUST-ID` (`PIC S9(15) COMP-3`), `WS-PHONE-NUMBER` (area/prefix/
  suffix): as in `MD022EC`.
- `WS-TARGET-DATE`: same formula as `MD022EC` —
  `(PROC-DATE-ISO − WS-INTER-DAYS DAYS) + 1 YEAR`.
- Dead/commented fields `WS-SEND-SMS-PUSH-SW` / `WS-WILDFIRE-ZIP` — the
  same CA-wildfire suppression logic seen in the `MD022EX`/`MD022ER`
  family, added and then reverted here too.

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens both output files, gets processing
   date, computes target date from the SYSIN interval, opens the
   `LATEPAY` cursor, writes header rows to both files.
2. **2000-PROCESS-CURSOR** loops per fetched row until SQLCODE 100; for
   each non-blank club/customer id row, performs
   **3000-GENERATE-SMS-PUSH** and increments the extract counter.
3. **3000-GENERATE-SMS-PUSH**:
   - **7000-CALL-MC501BCD**: fetches first name and qualifying cell
     phone via `MC501BCD`.
   - If a phone number was found, **7100-CHECK-CONSENT** calls
     `MC556BR`.
   - If consented, **4000-WRITE-SMS-RECORD** writes the SMS detail
     record.
   - **5000-WRITE-PUSH-RECORD** is performed **unconditionally** for
     every row with a phone found by `7000` (Push does not require SMS
     consent) — it is called after the SMS `IF` block regardless of the
     consent outcome.
4. **9999-FINAL-RTN**: closes the cursor and displays extracted/SMS-
   written/Push-written counts.

## Modification History

| Date | Ticket | Description | By |
|---|---|---|---|
| 08/23/2024 | MEM-479718 | Add first name to SMS and Push file | Rathna R |
| 01/16/2025 | MEM-480330 | Added fix to block SMS/Push for selected CA wildfire zip codes | Priya C |
| 01/16/2025 | MEM-480960 | Removed the MEM-480330 changes (same day per header, though the removal ticket date in the code header — `01/16/2025` — appears to duplicate the add date; treat as approximate) | Praveena |

## Ambiguous / Environment-Dependent Notes

- The `MEM-480960` "removed changes" log line is dated `01/16/2025`,
  identical to the `MEM-480330` line that added the change it reverts —
  this is very likely a transcription/typo in the source comment header
  (the sibling programs show the actual revert happening 06/11/25); not
  corrected here, just flagged.
- Same date-arithmetic pattern (`− interval + 1 YEAR`) as `MD022EC`; see
  that document's ambiguity note — business rationale not evident from
  source.
- Push notifications are written whenever a valid cell phone is found,
  with no SMS-consent gate — confirm this is the intended behavior
  (Push and SMS may legitimately have different consent regimes) rather
  than a gap, before using this as a base for any Apex reimplementation.
