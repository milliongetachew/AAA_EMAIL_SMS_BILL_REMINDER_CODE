/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§5 and
 * docs/salesforce-design/workflows.md §1.
 *
 * Replaces MD021EX, MD022EX, MD022ER, MD022EC, MD022LP, and md022cc: a
 * single config-driven batch that runs one Renewal_Notification_Rule__mdt
 * at a time (Source_Program__c identifies which legacy program's behavior
 * a given rule reproduces). Implements Database.AllowsCallouts because
 * finish() uploads the run's accumulated SMS/Push extract file(s) to
 * MOVEit (see NotificationGatewayService) — execute() itself only appends
 * rows in memory and does not call out. Implements Database.Stateful so
 * the same NotificationGatewayService instance (and its buffered rows)
 * survives across every execute() invocation in the run, producing ONE
 * extract file per channel per run instead of one per batch scope — this
 * mirrors the legacy programs, which held OSMSFILE/OUTSMS etc. open for
 * the whole run and closed it once at end-of-job.
 */
public with sharing class MembershipRenewalNotificationBatch implements
        Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final String ruleDeveloperName;

    // @TestVisible so unit tests can exercise execute()/finish() directly
    // with an in-memory Renewal_Notification_Rule__mdt (CMDT records
    // cannot be inserted via DML in tests) without requiring start() to
    // resolve a real deployed CMDT record first.
    @TestVisible
    private Renewal_Notification_Rule__mdt rule;

    // Default instance lets tests call execute()/finish() directly (as
    // testFinish_logsSummaryCountersWithoutError does) without requiring
    // start() to run first; start() replaces this with a
    // sourceProgram-specific instance once the CMDT rule is resolved.
    // @TestVisible so tests can queue rows without going through a real
    // Asset/Contact query.
    @TestVisible
    private NotificationGatewayService gateway = new NotificationGatewayService(null);

    // Counters mirror the legacy 2050-EOF-ROUTINE / Z0000-EOF-ROUTINE
    // display totals (input, PIT, no-cell, no-consent, no-amount, output).
    // smsSentCount/pushSentCount now count rows successfully QUEUED into
    // today's extract file, not confirmed-delivered messages — the legacy
    // programs counted written output records the same way, with no
    // delivery confirmation of their own either.
    public Integer inputCount = 0;
    public Integer pitSkipCount = 0;
    public Integer noCellCount = 0;
    public Integer noConsentCount = 0;
    public Integer noAmountCount = 0;
    public Integer smsSentCount = 0;
    public Integer pushSentCount = 0;

    public MembershipRenewalNotificationBatch(String ruleDeveloperName) {
        this.ruleDeveloperName = ruleDeveloperName;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        rule = [
            SELECT Source_Program__c, Club_Code__c, Campaign_Codes__c, Billing_Event_Codes__c,
                   Exclude_Bill_Plan_Types__c, Exclude_Bill_Cycles__c, Day_Offset__c,
                   Date_Formula__c, Requires_SMS_Consent__c, Requires_Push__c,
                   Requires_Amount_Due_Gt_Zero__c, Requires_No_Payment_In_Transit__c,
                   Bill_Plan_Filter__c
            FROM Renewal_Notification_Rule__mdt
            WHERE DeveloperName = :ruleDeveloperName AND Active__c = true
            LIMIT 1
        ];

        gateway = new NotificationGatewayService(rule.Source_Program__c);

        Date targetDate = RenewalEligibilityRules.computeTargetDate(System.today(), rule);

        // Replaces the CUSTID/LATEPAY cursor joins in each legacy program:
        // household + product-detail + member-info, filtered by bill-plan
        // and effective/renewal-term-expiration date. Club scoping
        // (blank = all clubs, matching MD021EX/MD022EX behavior) mirrors
        // Renewal_Notification_Rule__mdt.Club_Code__c.
        String query = 'SELECT Id, ContactId, AccountId, Club_Code__c, Bill_Plan_Type__c, ' +
                'Next_Bill_Event_Code__c, Campaign_Code__c, Membership_Number__c, ' +
                'Current_Term_Expiration_Date__c, Renewal_Term_Expiration_Date__c ' +
                'FROM Asset ' +
                'WHERE Renewal_Term_Expiration_Date__c = :targetDate ' +
                'AND (:rule.Bill_Plan_Filter__c = null OR Bill_Plan_Type__c = :rule.Bill_Plan_Filter__c)';
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<Asset> scope) {
        inputCount += scope.size();

        Set<Id> contactIds = new Set<Id>();
        Set<Id> billingAccountIds = new Set<Id>();
        for (Asset a : scope) {
            if (a.ContactId != null) {
                contactIds.add(a.ContactId);
            }
        }

        Map<Id, Contact> contactsById = new Map<Id, Contact>(
                [SELECT Id, FirstName, MobilePhone, Email FROM Contact WHERE Id IN :contactIds]);

        // Replaces FN435BT: bulk-fetch open/processing payments once per
        // scope rather than one subroutine call per member.
        Map<Id, List<SObject>> paymentsByBillingAccount = loadPaymentsInTransit(scope);

        // Replaces MD610BR: bulk-fetch amount-due once per scope.
        Map<Id, Decimal> amountDueByAsset = loadAmountDue(scope);

        CorrespondenceLogger logger = new CorrespondenceLogger();

        for (Asset a : scope) {
            Contact c = contactsById.get(a.ContactId);
            Boolean hasUsablePhone = c != null && String.isNotBlank(c.MobilePhone);
            Boolean pit = RenewalEligibilityRules.hasPaymentInTransit(a.AccountId, paymentsByBillingAccount);
            Decimal amountDue = amountDueByAsset.get(a.Id);

            RenewalEligibilityRules.EligibilityResult eligibility =
                    RenewalEligibilityRules.evaluate(a, c, rule, pit, hasUsablePhone, amountDue);

            if (eligibility.skipReason == 'PAYMENT_IN_TRANSIT') {
                pitSkipCount++;
                continue;
            }
            if (eligibility.skipReason == 'NO_CELL_PHONE') {
                noCellCount++;
                continue;
            }
            if (eligibility.skipReason == 'NO_AMOUNT_DUE') {
                noAmountCount++;
                continue;
            }
            if (eligibility.skipReason == 'NO_CONSENT') {
                noConsentCount++;
                continue;
            }
            if (eligibility.skipReason == 'BILLING_EVENT_FILTER'
                    || eligibility.skipReason == 'CAMPAIGN_CODE_NOT_WHITELISTED') {
                continue;
            }

            Map<String, Object> mergeFields = new Map<String, Object>{
                'firstName' => c?.FirstName,
                'membershipNumber' => a.Membership_Number__c,
                'amountDue' => amountDue,
                'expirationDate' => a.Current_Term_Expiration_Date__c
            };

            if (eligibility.smsEligible) {
                NotificationGatewayService.QueueResult smsResult =
                        gateway.queueSms(c.MobilePhone, rule.Source_Program__c, mergeFields);
                logger.add(a.Id, c.Id, CorrespondenceLogger.Channel.SMS, rule.Source_Program__c,
                        smsResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        rule.Source_Program__c);
                if (smsResult.queued) {
                    smsSentCount++;
                }
            }
            if (eligibility.pushEligible) {
                NotificationGatewayService.QueueResult pushResult =
                        gateway.queuePush(String.valueOf(a.Id), rule.Source_Program__c, mergeFields);
                logger.add(a.Id, c.Id, CorrespondenceLogger.Channel.PUSH, rule.Source_Program__c,
                        pushResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        rule.Source_Program__c);
                if (pushResult.queued) {
                    pushSentCount++;
                }
            }
        }

        logger.flush();
    }

    public void finish(Database.BatchableContext bc) {
        // Replaces CLOSE OUTPUT-FILE + the downstream job's pickup: upload
        // this run's accumulated SMS/Push extract file(s) to MOVEit exactly
        // once, after every execute() scope has run.
        List<NotificationGatewayService.FlushResult> flushResults = gateway.flush();

        // Replaces the legacy 2050-EOF-ROUTINE / Z0000-EOF-ROUTINE DISPLAY
        // statements — surfaced here via debug logging as a scaffold
        // placeholder; production implementation should write these counts
        // (plus flushResults' file names/row counts/success flags) to a
        // job-run log record or an AsyncApexJob-linked summary object.
        System.debug(LoggingLevel.INFO, 'MembershipRenewalNotificationBatch[' + rule?.Source_Program__c + ']'
                + ' input=' + inputCount
                + ' pitSkip=' + pitSkipCount
                + ' noCell=' + noCellCount
                + ' noConsent=' + noConsentCount
                + ' noAmount=' + noAmountCount
                + ' smsSent=' + smsSentCount
                + ' pushSent=' + pushSentCount
                + ' filesUploaded=' + flushResults.size());
    }

    @TestVisible
    private Map<Id, List<SObject>> loadPaymentsInTransit(List<Asset> scope) {
        // ASSUMPTION: blng__Payment__c.blng__BillingAccount__c and
        // blng__Status__c field names must be validated per HLD §6.
        Map<Id, List<SObject>> result = new Map<Id, List<SObject>>();
        Set<Id> billingAccountIds = new Set<Id>();
        for (Asset a : scope) {
            if (a.AccountId != null) {
                billingAccountIds.add(a.AccountId);
            }
        }
        if (billingAccountIds.isEmpty()) {
            return result;
        }
        for (SObject p : Database.query(
                'SELECT Id, blng__BillingAccount__c, blng__Status__c FROM blng__Payment__c ' +
                'WHERE blng__BillingAccount__c IN :billingAccountIds AND blng__Status__c IN (\'Processing\',\'Pending\')')) {
            Id baId = (Id) p.get('blng__BillingAccount__c');
            if (!result.containsKey(baId)) {
                result.put(baId, new List<SObject>());
            }
            result.get(baId).add(p);
        }
        return result;
    }

    @TestVisible
    private Map<Id, Decimal> loadAmountDue(List<Asset> scope) {
        // ASSUMPTION: blng__Invoice__c.blng__AssetId__c/blng__Balance__c
        // field names must be validated per HLD §6.
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        Set<Id> assetIds = new Set<Id>();
        for (Asset a : scope) {
            assetIds.add(a.Id);
        }
        for (SObject inv : Database.query(
                'SELECT blng__AssetId__c, blng__Balance__c FROM blng__Invoice__c ' +
                'WHERE blng__AssetId__c IN :assetIds')) {
            Id assetId = (Id) inv.get('blng__AssetId__c');
            Decimal balance = (Decimal) inv.get('blng__Balance__c');
            Decimal running = result.containsKey(assetId) ? result.get(assetId) : 0;
            result.put(assetId, running + (balance == null ? 0 : balance));
        }
        return result;
    }
}
