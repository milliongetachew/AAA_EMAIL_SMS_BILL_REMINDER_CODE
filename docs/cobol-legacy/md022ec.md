# MD022EC

Source: `attachments/MD022EC.txt`

## Summary

MD022EC creates an SMS push file for members who are past their renewal
due date (originally +3 days past, later changed to +5) and who belong
to specific marketing campaigns (a growing whitelist of campaign codes
tied to club `215`, and later several other clubs). It is a targeted,
campaign-code-gated variant of the late-payment SMS reminder family —
over its modification history it was repeatedly extended club-by-club
(ACMO, TX, AL/NNE/NM/TW/HI, EC) each time a new marketing campaign needed
to be included.

## Inputs and Outputs

- **Output file**: `SMS-FILE` (DD `OSMSFILE`, PIC X(120)) — a single
  fixed-format SMS extract file (header + detail records, see
  `MRD022EC` copybook).
- **Runtime parameter**: `WS-SYSIN-AREA` / `WS-INTERVAL-DAYS` — read via
  `ACCEPT ... FROM SYSIN`, a 2-digit number of days supplied by the JCL
  step's `SYSIN` DD. This is the "+N days past renewal" interval (e.g. 5).
- **DB2 tables**: `MBRSHP_HOUSEHOLD` (`MBRHSHLD`), `MBRSHP_NEXT_EVENT`
  (`MBRNXEVT`), `MBR_INFO`/`MEMBER` (`MEMBER`), `SQLCA`.
- **Cursor `LATEPAY`**: joins household, product detail, next-event, and
  member-info where `REN_TERM_EXP_D = :WS-TARGET-DATE`, restricted to
  either (club `'215'` with campaign code in a growing whitelist
  `'9000068'…'9000088'`) or (clubs `'065','252','001','018','258','601',
  '036'` with a narrower campaign-code whitelist), role `'00'`, currently
  effective, `FK_MBR_BILL_EVENT IN ('04','40','41','55','56','57','58',
  '59')`, excluding bill-plan types `'AC'`/`'AH'` and bill cycles
  `'IM'`/`'MA'`/`'NB'`.
- **External subprograms**: `MD930BR` (processing date), `MC501BCD`
  (customer data/phone/zip/name), `MC556BR` (SMS consent). Several other
  subprogram names are declared (`MCFCCAUT`, `MD999CK`, `MD610BR`,
  `MD699BR`, `FN435BT`) but are **not called** anywhere in this program —
  they appear to be leftover declarations from the copy-and-modify
  process used to create this program from a sibling.
- **Copybooks**: `MRD022EC` (SMS header/detail record layout), `MRD930C`,
  `MAC501C`, `MAC556C`, `MAC900C`, `MRD900C`, `MRD901C`, `MRD903C`.

## Key Data Structures

- `WS-SMS-PUSH-REC-AREAS` (copybook `MRD022EC`): SMS header record
  (`WS-SMS-HEADER-RECORD`) and detail record (`WS-SMS-DETAIL-RECORD`)
  with fields for subscriber key, customer id, phone number, locale,
  club code, extract date, first name, and (as of MEM-480219) zip code.
- `WS-CUST-ID` (`PIC S9(15) COMP-3`): packed-decimal customer system id
  fetched from the cursor.
- `WS-PHONE-NUMBER` (area/prefix/suffix, each unsigned numeric): the
  qualifying cell phone found via `MC501BCD` (role `'CL'`, valid,
  non-expired, all-numeric parts > 0).
- `WS-TARGET-DATE`: computed as
  `CHAR(DATE(:PROC-DATE-ISO) - :WS-INTER-DAYS DAYS + 1 YEAR)` — i.e. the
  processing date minus the SYSIN interval, then shifted forward one
  year (see Ambiguity note on this date-arithmetic pattern, shared with
  `MD022LP` and `md022cc`).
- `MEMBER-CONSENT-SW` (level-88 `MEMBER-CONSENT-YES`/`NO`): result of the
  SMS consent check.

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens the output file, gets the
   processing date (`MD930BR`), computes the target date
   (**1200-CALC-TARGET-DATE**, using the SYSIN interval described
   above), opens the `LATEPAY` cursor, and writes the header record.
2. **2000-PROCESS-CURSOR** loops per fetched row (club, member id,
   customer id) until SQLCODE 100:
   - If club and customer id are non-blank/non-zero, performs
     **3000-GENERATE-SMS-FILE** and increments the extract counter.
3. **3000-GENERATE-SMS-FILE**:
   - **7000-CALL-MC501BCD**: calls `MC501BCD` for first name, zip code,
     and the first qualifying cell phone.
   - If a phone number was found, **7100-CHECK-CONSENT** calls
     `MC556BR` to determine SMS authorization
     (`MEMBER-CONSENT-YES`/`NO`).
   - If consented, **4000-WRITE-SMS-RECORD** builds and writes the
     detail record (subscriber key/customer id = customer id, phone,
     locale `en-US`, club code, extract date, first name, zip code) and
     increments the write counter.
4. **9999-FINAL-RTN**: closes the cursor and displays extracted/written
   counts.

## Modification History

| Date | Ticket | Description | By |
|---|---|---|---|
| 11/10/2024 | MEM-479990 | Initial install — create SMS files for EC at +3 days past renewal for memberships with campaign code 9000068 | Rathna R |
| 01/07/2025 | MEM-480219 | Change +3 days to +5 days; include ACMO members with specific campaign code (also added zip code to output) | Rathna R |
| 01/19/2025 | MEM-480323 | Include TX members with specific campaign code | Rathna R |
| 02/18/2025 | MEM-480324 | Include AL, NNE, NM, TW, HI with specific campaign code | Rathna R |
| 03/31/2025 | MEM-480325 | Include EC members with specific campaign code | GIT W |
| 05/06/2025 | MEM-480768 | Include new campaign code 9000083 | Rathna R |
| 07/31/2025 | MEM-481149 | Add new campaign codes 9000087 and 9000088 | GIT W |

## Ambiguous / Environment-Dependent Notes

- The SYSIN-supplied interval (`WS-INTERVAL-DAYS`) controls how far past
  renewal the target window is; its actual value at any given run is a
  JCL parameter not visible in this source (the modification log implies
  it has been `5` since MEM-480219, previously `3`).
- The target-date formula `(processing date − interval) + 1 year` is
  unusual: it effectively looks for members whose renewal-term
  expiration falls on "interval days before today, one year from now."
  This same formula appears verbatim in `MD022LP` and `md022cc`. The
  business intent (why add a year rather than simply add the interval)
  is not documented in-source; flagging rather than reinterpreting.
- Several called-program names are declared in `CALLED-PGMS` but never
  invoked (`MCFCCAUT`, `MD999CK`, `MD610BR`, `MD699BR`, `FN435BT`) —
  likely inherited unchanged from whatever program this was cloned from;
  they have no runtime effect.
- Program name literal used when calling `MC501BCD` is `'MD022EC '`
  (correct), consistent with `PROGRAM-ID`.
