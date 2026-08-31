/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §4/§5/§6 and
 * docs/salesforce-design/workflows.md §4.
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
 */
public with sharing class EftReconciliationBatch implements
        Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    // Legacy day-count threshold from MEM-481325 (8250-CHECK-NBR-DAYS-EXPIRE):
    // suppress the printed CAU letter if 23 days or fewer remain to expiration.
    private static final Integer PRINT_SUPPRESSION_DAYS_THRESHOLD = 23;

    // Lodge codes treated as "out of territory" in MC501BCD's response
    // (docs/cobol-legacy/md058cb.md, OUTOF-TERRITORY level-88).
    private static final Set<String> OUT_OF_TERRITORY_LODGE_CODES = new Set<String>{ '1', '3', '4', '6' };

    // Held across execute() invocations (Database.Stateful) so one run
    // produces one SMS/Push/Email extract file each, not one per scope;
    // flush()ed once in finish().
    @TestVisible
    private NotificationGatewayService gateway = new NotificationGatewayService('MD058CB');

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Replaces reading CAUCCREJ-FILE (DD CAUCCREJ) row by row; the
        // staging object Eft_Cau_Reject__c is the inbound-integration
        // replacement for that file — see HLD §4.
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
            SELECT Id, ContactId, Contact.Email, Contact.FirstName, Contact.MobilePhone,
                   AccountId, Club_Code__c, Bill_Plan_Type__c, Next_Bill_Plan_Type__c,
                   Membership_Number__c, Current_Term_Expiration_Date__c, Lodge_Type_Code__c
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
            if (asset.Bill_Plan_Type__c != 'AC') {
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8500-CHECK-BILLPLN-NXTEVT: check the upcoming
            // billing-cycle bill plan too.
            if (asset.Next_Bill_Plan_Type__c != null && asset.Next_Bill_Plan_Type__c != 'AC') {
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8600-GET-LODGE-TYPE (MC501BCD lodge codes).
            Boolean outOfTerritory = isOutOfTerritory(asset.Lodge_Type_Code__c);
            if (outOfTerritory) {
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.LETTER,
                        'MD58TERR', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
                toMarkProcessed.add(new Eft_Cau_Reject__c(Id = reject.Id, Processed__c = true));
                continue;
            }

            // Replaces 8250-CHECK-NBR-DAYS-EXPIRE (UT020DT, MEM-481325):
            // suppress the printed-letter equivalent within 23 days of
            // expiration, but still allow digital notifications below.
            Boolean suppressPrintedLetter = daysToExpiration(asset.Current_Term_Expiration_Date__c, processingDate)
                    <= PRINT_SUPPRESSION_DAYS_THRESHOLD;
            if (suppressPrintedLetter) {
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.LETTER,
                        'MD58SYNC', CorrespondenceLogger.Status.SUPPRESSED, 'MD058CB');
            }

            // Replaces 1900-CREATE-OUTPUT-FILES (MEM-480905): generate
            // SMS / Push / Email notifications regardless of the
            // old/new-path outcome above.
            Map<String, Object> mergeFields = new Map<String, Object>{
                'firstName' => asset.Contact?.FirstName,
                'membershipNumber' => asset.Membership_Number__c,
                'oldCardLastFour' => reject.Old_Card_Last_Four__c,
                'oldCardExpiration' => reject.Old_Card_Expiration__c,
                'expirationDate' => asset.Current_Term_Expiration_Date__c
            };

            if (String.isNotBlank(asset.Contact?.MobilePhone)) {
                NotificationGatewayService.QueueResult pushResult =
                        gateway.queuePush(String.valueOf(asset.Id), 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.PUSH, '868',
                        pushResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD058CB');

                NotificationGatewayService.QueueResult smsResult =
                        gateway.queueSms(asset.Contact.MobilePhone, 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.SMS, '768',
                        smsResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD058CB');
            }

            if (String.isNotBlank(asset.Contact?.Email)) {
                NotificationGatewayService.QueueResult emailResult =
                        gateway.queueEmail(asset.Contact.Email, 'CAU_REJECT', mergeFields);
                logger.add(asset.Id, asset.ContactId, CorrespondenceLogger.Channel.EMAIL, '668',
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

    @TestVisible
    private Boolean isOutOfTerritory(String lodgeTypeCode) {
        return lodgeTypeCode != null && OUT_OF_TERRITORY_LODGE_CODES.contains(lodgeTypeCode);
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
