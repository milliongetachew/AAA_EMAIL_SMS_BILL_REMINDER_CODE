/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§5/§6 and
 * docs/salesforce-design/workflows.md §1, and
 * docs/salesforce-design/data-dictionary-reference.md for the real,
 * field-verified schema this class now targets.
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
 *
 * CORRECTED per the data-dictionary audit (see HLD §1/§6):
 *  - Members are Person Accounts. Asset.ContactId does NOT exist in this
 *    org's schema the way an earlier draft assumed — Asset.AccountId
 *    points directly at the Person Account. There is no separate Contact
 *    query; the "Contact" query below is now a Person Account query keyed
 *    off Asset.AccountId, and "usable phone" is judged from
 *    PersonMobilePhone + Mobile_Status__pc (a real deliverability
 *    picklist), not a bare null check.
 *  - The Asset SOQL below now selects real, confirmed fields
 *    (Club__c, Bill_Plan__c, Member_Number__c, CurrentLifecycleEndDate,
 *    LifecycleEndDate) in place of placeholders that don't exist on Asset
 *    in this org (Club_Code__c, Bill_Plan_Type__c, Membership_Number__c,
 *    Current_Term_Expiration_Date__c, Renewal_Term_Expiration_Date__c).
 *    Next_Bill_Event_Code__c and Campaign_Code__c are DROPPED from the
 *    query entirely — neither exists on Asset in the audited schema, and
 *    there is currently no confirmed way to source either value (see
 *    RenewalEligibilityRules class header and HLD §1/§6 "Billing/Payment
 *    gap" / campaign-code lineage gap). Rules that depend on those two
 *    inputs will effectively no-op until that data becomes available.
 *  - loadPaymentsInTransit()/loadAmountDue() are left as UNCHANGED,
 *    explicitly-flagged blng__ placeholders — the data dictionary confirms
 *    no Billing/Payment object exists anywhere in this org's audited
 *    schema, so there is no different field name to substitute; this
 *    remains a genuinely open question, not a naming detail. Do not treat
 *    the presence of these placeholders as evidence Billing is installed.
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
    // Asset/Person Account query.
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
        //
        // TARGET-DATE FIELD ASSUMPTION: Asset.LifecycleEndDate is used
        // here as the closest confirmed stand-in for the legacy
        // "renewal-term expiration date" cursor filter. Whether
        // LifecycleEndDate or CurrentLifecycleEndDate is the correct
        // semantic match for that legacy concept is UNCONFIRMED — see HLD
        // §1/§6 — and must be validated with the business before cutover.
        String query = 'SELECT Id, AccountId, Club__c, Bill_Plan__c, ' +
                'Member_Number__c, CurrentLifecycleEndDate, LifecycleEndDate ' +
                'FROM Asset ' +
                'WHERE LifecycleEndDate = :targetDate ' +
                'AND (:rule.Bill_Plan_Filter__c = null OR Bill_Plan__c = :rule.Bill_Plan_Filter__c)';
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<Asset> scope) {
        inputCount += scope.size();

        Set<Id> accountIds = new Set<Id>();
        for (Asset a : scope) {
            if (a.AccountId != null) {
                accountIds.add(a.AccountId);
            }
        }

        // Person Account query replaces the former Contact query — the
        // member IS the Account (Asset.AccountId points directly at the
        // Person Account, there is no Asset.ContactId in this schema).
        // Mobile_Status__pc/Email_Status__pc are the real deliverability
        // picklists (Valid/Invalid/Transactional Call Only/Declined).
        Map<Id, Account> personAccountsById = new Map<Id, Account>(
                [SELECT Id, FirstName, PersonMobilePhone, PersonEmail, Mobile_Status__pc,
                        Email_Status__pc, Consent_for_SMS__c, Member_Number__c
                 FROM Account WHERE Id IN :accountIds]);

        // Replaces FN435BT: bulk-fetch open/processing payments once per
        // scope rather than one subroutine call per member. UNRESOLVED —
        // see class header and loadPaymentsInTransit()'s own comment.
        Map<Id, List<SObject>> paymentsByBillingAccount = loadPaymentsInTransit(scope);

        // Replaces MD610BR: bulk-fetch amount-due once per scope.
        // UNRESOLVED — see class header and loadAmountDue()'s own comment.
        Map<Id, Decimal> amountDueByAsset = loadAmountDue(scope);

        // Real Campaign_Code__c query, bulk-preloaded once per scope
        // rather than per row — see RenewalEligibilityRules class header.
        // Only meaningful once Asset carries a resolvable campaign-code
        // identifier (currently a data-lineage gap — see HLD §1/§6), so
        // this is wired up but will typically have nothing to match
        // against yet.
        Map<String, Campaign_Code__c> activeCampaignCodesByName =
                String.isNotBlank(rule.Club_Code__c)
                        ? RenewalEligibilityRules.getActiveCampaignCodesByName(rule.Club_Code__c, System.today())
                        : null;

        CorrespondenceLogger logger = new CorrespondenceLogger();

        for (Asset a : scope) {
            Account personAccount = personAccountsById.get(a.AccountId);
            Boolean hasUsablePhone = isPhoneDeliverable(personAccount);
            Boolean pit = RenewalEligibilityRules.hasPaymentInTransit(a.AccountId, paymentsByBillingAccount);
            Decimal amountDue = amountDueByAsset.get(a.Id);

            RenewalEligibilityRules.EligibilityResult eligibility =
                    RenewalEligibilityRules.evaluate(a, personAccount, rule, pit, hasUsablePhone, amountDue,
                            activeCampaignCodesByName);

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
                'firstName' => personAccount?.FirstName,
                'membershipNumber' => a.Member_Number__c,
                'amountDue' => amountDue,
                'expirationDate' => a.CurrentLifecycleEndDate
            };

            if (eligibility.smsEligible) {
                NotificationGatewayService.QueueResult smsResult =
                        gateway.queueSms(personAccount.PersonMobilePhone, rule.Source_Program__c, mergeFields);
                logger.add(a.Id, personAccount.Id, CorrespondenceLogger.Channel.SMS, rule.Source_Program__c,
                        smsResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        rule.Source_Program__c);
                if (smsResult.queued) {
                    smsSentCount++;
                }
            }
            if (eligibility.pushEligible) {
                NotificationGatewayService.QueueResult pushResult =
                        gateway.queuePush(String.valueOf(a.Id), rule.Source_Program__c, mergeFields);
                logger.add(a.Id, personAccount.Id, CorrespondenceLogger.Channel.PUSH, rule.Source_Program__c,
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

    /**
     * Replaces MC501BCD's "has a usable phone" gate with the real
     * deliverability signal: PersonMobilePhone present AND
     * Mobile_Status__pc not Invalid/Declined. 'Transactional Call Only' is
     * treated as usable here (this is about whether a message CAN be
     * delivered, not whether marketing consent exists — that is the
     * separate Requires_SMS_Consent__c / Account.Consent_for_SMS__c gate).
     */
    @TestVisible
    private Boolean isPhoneDeliverable(Account personAccount) {
        if (personAccount == null || String.isBlank(personAccount.PersonMobilePhone)) {
            return false;
        }
        String status = personAccount.Mobile_Status__pc;
        return status == null || (status != 'Invalid' && status != 'Declined');
    }

    @TestVisible
    private Map<Id, List<SObject>> loadPaymentsInTransit(List<Asset> scope) {
        // UNRESOLVED, not just unconfirmed field names: the data
        // dictionary audit found no Billing/Payment object anywhere in
        // this org's 7 audited objects. blng__Payment__c is left as an
        // unchanged, explicitly-flagged placeholder pending a separate
        // billing/payment investigation — see class header and HLD §1/§6
        // "Billing/Payment gap". Do not swap in a different guessed
        // object/field name.
        Map<Id, List<SObject>> result = new Map<Id, List<SObject>>();
        Set<Id> billingAccountIds = new Set<Id>();
        for (Asset a : scope) {
            if (a.AccountId != null) {
                // NOTE: Asset.AccountId is the Person Account itself in
                // this org (there is no separate billing-account object
                // confirmed) — reused here as the best available key
                // pending resolution of the Billing/Payment gap.
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
        // UNRESOLVED, not just unconfirmed field names — see
        // loadPaymentsInTransit() above and HLD §1/§6 "Billing/Payment
        // gap". blng__Invoice__c is left unchanged and explicitly flagged.
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
