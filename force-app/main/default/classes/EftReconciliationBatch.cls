/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§4/§5/§6 and
 * docs/salesforce-design/workflows.md §4, and
 * docs/salesforce-design/data-dictionary-reference.md for the real,
 * field-verified schema this class now targets.
 *
 * Replaces MD058CB's core bill-plan reconciliation loop (its "new path"
 * SMS/Push/Email notification behavior added under MEM-480905) plus the
 * out-of-sync / out-of-territory reporting branches of its older
 * letter-queue logic. The historical bill-plan-flip-to-AM behavior
 * (2210-CHANGE-HOUSEHOLD-AM / 2220-UPDATE-NEXT-EVENT /
 * 2230-WRITE-MEMBER-SUMMARY) is deliberately NOT reimplemented here,
 * matching that logic's dormant/disabled state in the current production
 * COBOL source (MEM-480905) — see HLD §6 before re-enabling.
 *
 * MD058CB's mainframe checkpoint/restart and GO TO-based deadlock retry
 * loop (9000-ERROR-HANDLING) have no literal Apex equivalent; this batch
 * instead relies on Batch Apex's native per-scope transaction rollback and
 * on Eft_Cau_Reject__c.Processed__c to make reprocessing idempotent and the
 * job safely re-runnable — see HLD §6 for the resulting semantic change.
 *
 * OUTPUT side: execute() appends rows to in-memory SMS/Push/Email extracts
 * via NotificationGatewayService (replacing MD058CB's 1900-CREATE-OUTPUT-
 * FILES writes to OUTSMS/OUTPSH/OUTEML), and finish() uploads each
 * channel's accumulated extract to MOVEit exactly once per run. Implements
 * Database.Stateful so the same NotificationGatewayService instance (and
 * its buffered rows) survives across every execute() invocation, producing
 * ONE file per channel per run rather than one per batch scope.
 *
 * CORRECTED per the data-dictionary audit (see HLD §1/§6):
 *  - Members are Person Accounts. Asset.ContactId does NOT exist in this
 *    org's schema — Asset.AccountId points directly at the Person Account,
 *    whose PersonEmail/PersonMobilePhone/FirstName replace every
 *    Contact.* reference below.
 *  - Club_Code__c/Bill_Plan_Type__c/Membership_Number__c/
 *    Current_Term_Expiration_Date__c are replaced with the real, confirmed
 *    fields Club__c, Bill_Plan__c, Member_Number__c, CurrentLifecycleEndDate.
 *  - Out-of-territory is now Account.Out_Of_Territory__c (real, confirmed
 *    boolean field) — this REPLACES the former guessed lodge-code
 *    equivalent entirely, per HLD §1/§2 ("the real field for MD058CB's
 *    out-of-territory branch"). The lodge-code constant/method are removed.
 *  - Next_Bill_Plan_Type__c remains an UNCHANGED, unconfirmed placeholder
 *    — no "next billing-cycle bill plan" field exists anywhere in the data
 *    dictionary's Asset sheet; see HLD §6.
 */
public with sharing class EftReconciliationBatch implements
        Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    // Legacy day-count threshold from MEM-481325 (8250-CHECK-NBR-DAYS-EXPIRE):
    // suppress the printed CAU letter if 23 days or fewer remain to expiration.
    private static final Integer PRINT_SUPPRESSION_DAYS_THRESHOLD = 23;

    // Held across execute() invocations (Database.Stateful) so one run
    // produces one SMS/Push/Email extract file each, not one per scope;
    // flush()ed once in finish().
    @TestVisible
    private NotificationGatewayService gateway = new NotificationGatewayService('MD058CB');

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Replaces reading CAUCCREJ-FILE (DD CAUCCREJ) row by row; the
        // staging object Eft_Cau_Reject__c is the inbound-integration
        // replacement for that file — see HLD §4. Eft_Cau_Reject__c is not
        // covered by the data-dictionary audit, so its field names remain
        // unchanged net-new proposals.
        return Database.getQueryLocator([
            SELECT Id, Club_Code__c, Membership_Number__c, Old_Card_Last_Four__c,
                   Old_Card_Expiration__c, Related_Asset__c
            FROM Eft_Cau_Reject__c
            WHERE Processed__c = false
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Eft_Cau_Reject__c> scope) {
        Date processingDate = System.today();

        Set<Id> assetIds = new Set<Id>();
        for (Eft_Cau_Reject__c reject : scope) {
            if (reject.Related_Asset__c != null) {
                assetIds.add(reject.Related_Asset__c);
            }
        }

        Map<Id, Asset> assetsById = new Map<Id, Asset>([
            SELECT Id, AccountId, Account.PersonEmail, Account.FirstName, Account.PersonMobilePhone,
                   Account.Out_Of_Territory__c, Club__c, Bill_Plan__c, Next_Bill_Plan_Type__c,
                   Member_Number__c, CurrentLifecycleEndDate
            FROM Asset
            WHERE Id IN :assetIds
        ]);

        CorrespondenceLogger logger = new CorrespondenceLogger();
        List<Eft_Cau_Reject__c> toMarkProcessed = new List<Eft_Cau_Reject__c>();

        for (Eft_Cau_Reject__c reject : scope) {
            Asset asset = assetsById.get(reject.Related_Asset__c);
            if (asset == null) {
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8200-CHECK-BILLPLAN-AC: if the household's bill
            // plan is no longer AC by the time we process the reject, log
            // an out-of-sync record instead of a stale bill-plan flip.
            if (asset.Bill_Plan__c != 'AC') {
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8500-CHECK-BILLPLN-NXTEVT: check the upcoming
            // billing-cycle bill plan too. UNRESOLVED field — see class
            // header; no confirmed "next cycle" field exists in the data
            // dictionary, so this check may never fire in practice.
            if (asset.Next_Bill_Plan_Type__c != null && asset.Next_Bill_Plan_Type__c != 'AC') {
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8600-GET-LODGE-TYPE (MC501BCD lodge codes 1/3/4/6).
            // CORRECTED: Account.Out_Of_Territory__c is the real, confirmed
            // field for this branch — the guessed lodge-code equivalent is
            // removed entirely, not just relabeled. See HLD §1/§2/§6.
            Boolean outOfTerritory = isOutOfTerritory(asset.Account);
            if (outOfTerritory) {
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.LETTER,
                        'MD58TERR', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8250-CHECK-NBR-DAYS-EXPIRE (UT020DT, MEM-481325):
            // suppress the printed-letter equivalent within 23 days of
            // expiration, but still allow digital notifications below.
            // CurrentLifecycleEndDate is used as the closest confirmed
            // stand-in for "current term expiration" — exact semantic
            // match UNCONFIRMED, see HLD §1/§6.
            Boolean suppressPrintedLetter = daysToExpiration(asset.CurrentLifecycleEndDate, processingDate)
                    <= PRINT_SUPPRESSION_DAYS_THRESHOLD;
            if (suppressPrintedLetter) {
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
            }

            // Replaces 1900-CREATE-OUTPUT-FILES (MEM-480905): generate
            // SMS / Push / Email notifications regardless of the
            // old/new-path outcome above.
            Map<String, Object> mergeFields = new Map<String, Object>{
                'firstName' => asset.Account?.FirstName,
                'membershipNumber' => asset.Member_Number__c,
                'oldCardLastFour' => reject.Old_Card_Last_Four__c,
                'oldCardExpiration' => reject.Old_Card_Expiration__c,
                'expirationDate' => asset.CurrentLifecycleEndDate
            };

            if (String.isNotBlank(asset.Account?.PersonMobilePhone)) {
                NotificationGatewayService.QueueResult pushResult =
                        gateway.queuePush(String.valueOf(asset.Id), 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.PUSH, '868',
                        pushResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD058CB');

                NotificationGatewayService.QueueResult smsResult =
                        gateway.queueSms(asset.Account.PersonMobilePhone, 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.SMS, '768',
                        smsResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD058CB');
            }

            if (String.isNotBlank(asset.Account?.PersonEmail)) {
                NotificationGatewayService.QueueResult emailResult =
                        gateway.queueEmail(asset.Account.PersonEmail, 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.AccountId, CorrespondenceLogger.Channel.EMAIL, '668',
                        emailResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD058CB');
            }

            toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
        }

        logger.flush();
        if (!toMarkProcessed.isEmpty()) {
            update toMarkProcessed;
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Replaces CLOSE OUTSMS/OUTPSH/OUTEML + the downstream job's
        // pickup: upload this run's accumulated SMS/Push/Email extract
        // file(s) to MOVEit exactly once, after every execute() scope has
        // run.
        List<NotificationGatewayService.FlushResult> flushResults = gateway.flush();

        // Replaces 2050-EOF-ROUTINE's extensive summary DISPLAY output —
        // see MembershipRenewalNotificationBatch.finish() for the same
        // scaffold placeholder pattern.
        System.debug(LoggingLevel.INFO, 'EftReconciliationBatch run complete. filesUploaded='
                + flushResults.size());
    }

    /**
     * Replaces 8600-GET-LODGE-TYPE / MC501BCD lodge codes 1/3/4/6 with the
     * real, confirmed Account.Out_Of_Territory__c field — see class header
     * and HLD §1/§2/§6. `personAccount` is the Person Account itself
     * (Asset.Account), not a related Contact.
     */
    @TestVisible
    private Boolean isOutOfTerritory(Account personAccount) {
        return personAccount != null && personAccount.Out_Of_Territory__c == true;
    }

    /** Stand-in for UT020DT's day-count-between-two-dates utility. */
    @TestVisible
    private Integer daysToExpiration(Date expirationDate, Date processingDate) {
        if (expirationDate == null) {
            return 9999;
        }
        return expirationDate.daysBetween(processingDate) * -1;
    }
}
