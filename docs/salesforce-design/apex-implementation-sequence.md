# Apex Implementation Sequence

The order to actually build the scaffold in `force-app/main/default/classes/`
into real, deployable code — driven by dependencies (what needs to exist
before the next thing can compile or be meaningfully tested), not by
alphabetical order or the order classes appear in the repo. See
`new-custom-objects-spec.md` for the metadata this sequence assumes, and
`docs/jira/revenue-cloud-migration-stories.csv` for how each wave maps to a
trackable story.

## Wave 0 — Metadata foundation (no Apex yet)

Nothing in Wave 1 compiles without these existing first.

1. **`Renewal_Notification_Rule__mdt`** — create the Custom Metadata Type,
   then populate one record per legacy program variant (`MD021EX`,
   `MD022EX`, `MD022ER`, `MD022EC`, `MD022LP`, `md022cc` — see the field
   table in `new-custom-objects-spec.md` §4 for the values each needs).
2. **`Correspondence_Log__c`** — create the custom object (§1 of the spec).
3. **`Eft_Cau_Reject__c`** — create the staging custom object (§2).
4. **`Card_Decline_Event__e`** — create the Platform Event (§3).

## Wave 1 — Foundation Apex (helpers, no orchestration)

Build and unit-test these independently before anything that consumes
them. All three can be fully unit tested now — HTTP callouts are mocked,
so the still-open MOVEit endpoint values don't block writing or testing
this code, only the *real* delivery working end to end later.

5. **`NotificationGatewayService` + `NotificationGatewayServiceTest`** —
   no dependencies on the other new metadata. Build first among the three;
   everything downstream calls it.
6. **`CorrespondenceLogger` + `CorrespondenceLoggerTest`** — depends on
   `Correspondence_Log__c` existing (Wave 0, step 2).
7. **`RenewalEligibilityRules` + `RenewalEligibilityRulesTest`** — depends
   on `Renewal_Notification_Rule__mdt` (Wave 0, step 1) and the real
   `Campaign_Code__c` object. Its payment-in-transit/amount-due gates are
   blocked on the Billing/Payment data source (see "External blockers"
   below) — build and test the rest of the gate chain now, stub those two
   gates behind the still-open question rather than waiting on it.

## Wave 2 — Orchestration classes

Build in this order — simplest and least externally-blocked first, so the
queue-then-flush pattern is proven end to end before tackling the classes
with open external dependencies:

8. **`BillingEmailQueueable` + `BillingEmailQueueableTest`** — build
   **first** in this wave. Depends only on Wave 1's `NotificationGatewayService`
   and `CorrespondenceLogger` — not blocked by the Billing/Payment gap at
   all, since its core logic (letter-139 suppression) needs no billing data.
   The cleanest class to prove the whole pattern works before the harder ones.
9. **`MembershipRenewalNotificationBatch` + `MembershipRenewalNotificationScheduler`**
   (+ their tests) — depends on `RenewalEligibilityRules` (step 7),
   `Renewal_Notification_Rule__mdt` records actually existing (Wave 0), and
   the real `Campaign_Code__c` object. Partially blocked: the
   payment-in-transit/amount-due gates won't be correct until the
   Billing/Payment source is resolved, but the rest (deliverability,
   consent, campaign-code, day-offset routing) can be built and tested now.
10. **`EftReconciliationBatch` + `EftReconciliationBatchTest`** — depends
    on `Eft_Cau_Reject__c` (Wave 0, step 3) **and** a real inbound
    integration actually populating it (not yet built — see "External
    blockers"). Build and test the batch logic itself now against
    manually-inserted test records; the inbound feed is a separate,
    parallel workstream.
11. **`CardDeclineDunningHandler` + `CardDeclineDunningHandlerTest`**,
    plus the trigger that isn't written yet (`CardDeclineEventTrigger` —
    see `new-custom-objects-spec.md` §3) — build **last**. Depends on
    `Card_Decline_Event__e` (Wave 0, step 4), and is the most externally
    blocked class: its amount-due gate needs the Billing/Payment source,
    and nothing publishes `Card_Decline_Event__e` yet (the publisher was
    never resolved — see `high-level-design.md` §4).

## External blockers — track separately, don't let them stall Wave 1/most of Wave 2

These aren't Apex work, and building code speculatively around a guess at
their answer has already caused rework once this session (see the MOVEit
correction history in `moveit-aft-reference.md`). Everything in Waves 0-2
above except the specific gates called out can be built and unit-tested
without waiting on these:

| Blocker | Blocks | Jira story |
|---|---|---|
| Real `folderId`/`source`/`dest` for MOVEit upload | `NotificationGatewayService.flush()` actually delivering (not writing/testing it) | *Confirm Real folderId/source/dest for MOVEit Upload* |
| Billing/Payment data source | PIT/amount-due gates in `RenewalEligibilityRules` and `MembershipRenewalNotificationBatch`; `CardDeclineDunningHandler`'s amount-due gate | *Resolve Billing/Payment Data Source* |
| `Card_Decline_Event__e` publisher | `CardDeclineDunningHandler` ever receiving real events | Same story as above (tied to the Billing/Payment gap) |
| `MD065CC` source code | A program not covered by this sequence at all | *Document MD065CC (Annual CC Decline) - Scope Gap* |
| `MD572EM` per-state split decision | Whether `CardDeclineDunningHandler`/`NotificationGatewayService` need to produce 9 files instead of 1 | Card-Decline story's acceptance criteria |

## After Wave 2 — parity and cutover

Not Apex-build work, but the natural next phase once all classes above are
real: the *Parallel Run & Validation* and *Cutover & Decommission* stories
already in `docs/jira/revenue-cloud-migration-stories.csv`.
