/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: execute() queries blng__Payment__c and blng__Invoice__c, so these
 * tests require the Billing managed package to be installed in the org
 * running them (see high-level-design.md §1/§6 "Billing/Payment gap" —
 * this remains a genuinely unresolved data source, not a confirmed one).
 * The `rule` member is set directly via its @TestVisible modifier to avoid
 * depending on a deployed Renewal_Notification_Rule__mdt record. As of the
 * MOVEit file-handoff correction (see NotificationGatewayService class
 * header), execute() itself never calls out — only finish()'s
 * gateway.flush() does — so most of these tests no longer need an
 * HttpCalloutMock at all; testFinish_uploadsQueuedExtractFile below is the
 * one that does.
 *
 * CORRECTED per data-dictionary-reference.md: members are Person Accounts,
 * not a separate Contact — Asset.AccountId points directly at the Person
 * Account, and "usable phone" is judged via PersonMobilePhone +
 * Mobile_Status__pc rather than a bare MobilePhone null check.
 */
@isTest
private class MembershipRenewalNotificationBatchTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"messageId":"MOCK-1"}');
            return res;
        }
    }

    @isTest
    static void testFinish_logsSummaryCountersWithoutError() {
        // Smoke test for finish() — mirrors 2050-EOF-ROUTINE's summary
        // DISPLAY, which in this scaffold is a debug-log placeholder (see
        // class header comment on MembershipRenewalNotificationBatch).
        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');
        batchInstance.rule = new Renewal_Notification_Rule__mdt(Source_Program__c = 'MD022EX');
        batchInstance.inputCount = 10;
        batchInstance.smsSentCount = 7;

        Test.startTest();
        batchInstance.finish(null);
        Test.stopTest();

        System.assertEquals(10, batchInstance.inputCount);
        System.assertEquals(7, batchInstance.smsSentCount);
    }

    @isTest
    static void testComputeTargetDate_usedByStart_matchesRuleFormula() {
        // Confirms the batch and RenewalEligibilityRules agree on target-date
        // math for a MD022EX-style (SIMPLE_OFFSET) rule — see
        // RenewalEligibilityRulesTest for the exhaustive date-formula cases.
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Date_Formula__c = 'SIMPLE_OFFSET', Day_Offset__c = 13);

        Test.startTest();
        Date target = RenewalEligibilityRules.computeTargetDate(Date.newInstance(2026, 8, 30), rule);
        Test.stopTest();

        System.assertEquals(Date.newInstance(2026, 9, 12), target);
    }

    @isTest
    static void testIsPhoneDeliverable_blankPhoneOrInvalidStatusIsNotUsable() {
        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');

        Account noPhone = new Account();
        Account invalidPhone = new Account(PersonMobilePhone = '5551234567');
        invalidPhone.put('Mobile_Status__pc', 'Invalid');
        Account validPhone = new Account(PersonMobilePhone = '5551234567');
        validPhone.put('Mobile_Status__pc', 'Valid');
        Account unknownStatusPhone = new Account(PersonMobilePhone = '5551234567');

        Test.startTest();
        Boolean noPhoneResult = batchInstance.isPhoneDeliverable(noPhone);
        Boolean invalidResult = batchInstance.isPhoneDeliverable(invalidPhone);
        Boolean validResult = batchInstance.isPhoneDeliverable(validPhone);
        Boolean unknownStatusResult = batchInstance.isPhoneDeliverable(unknownStatusPhone);
        Boolean nullAccountResult = batchInstance.isPhoneDeliverable(null);
        Test.stopTest();

        System.assertEquals(false, noPhoneResult, 'A blank PersonMobilePhone is never usable');
        System.assertEquals(false, invalidResult, 'Mobile_Status__pc = Invalid must not be treated as usable');
        System.assertEquals(true, validResult);
        System.assertEquals(true, unknownStatusResult,
                'A null deliverability status should not be treated as a hard block, matching the legacy null-check behavior it replaces');
        System.assertEquals(false, nullAccountResult);
    }

    @isTest
    static void testExecute_skipsWhenNoUsablePhone() {
        // Builds a minimal scope with no PersonMobilePhone on the related
        // Person Account and confirms the batch counts it as a "no cell"
        // skip rather than attempting a send — mirrors MD022EX's
        // WS-NO-CELL-COUNT.
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Account personAccount = new Account(LastName = 'Doe', FirstName = 'Jane');
        insert personAccount;

        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');
        batchInstance.rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'MD022EX', Requires_No_Payment_In_Transit__c = false,
                Requires_SMS_Consent__c = false, Requires_Amount_Due_Gt_Zero__c = false);

        // Constructed in memory only (not inserted) since Asset's custom
        // fields referenced by this scaffold are not deployed metadata —
        // see class header note.
        Asset a = new Asset(AccountId = personAccount.Id);

        Test.startTest();
        batchInstance.execute(null, new List<Asset>{ a });
        Test.stopTest();

        System.assertEquals(1, batchInstance.inputCount);
        System.assertEquals(1, batchInstance.noCellCount,
                'A Person Account with no PersonMobilePhone must be skipped and counted, matching MD022EX 2010');
        System.assertEquals(0, batchInstance.smsSentCount);
    }

    @isTest
    static void testExecute_queuesEligibleSmsRowThenFinishFlushesExtractFile() {
        // Confirms the queue-then-flush pattern end to end: execute()
        // appends a row without calling out, and finish() is the one place
        // that uploads the accumulated extract file to MOVEit (replacing
        // the legacy CLOSE OUTPUT-FILE + downstream pickup).
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Account personAccount = new Account(LastName = 'Doe', FirstName = 'Jane', PersonMobilePhone = '5551234567');
        insert personAccount;

        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');
        batchInstance.rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'MD022EX', Requires_No_Payment_In_Transit__c = false,
                Requires_SMS_Consent__c = false, Requires_Amount_Due_Gt_Zero__c = false);
        batchInstance.gateway = new NotificationGatewayService('MD022EX');

        Asset a = new Asset(AccountId = personAccount.Id);

        Test.startTest();
        batchInstance.execute(null, new List<Asset>{ a });
        batchInstance.finish(null);
        Test.stopTest();

        System.assertEquals(1, batchInstance.smsSentCount,
                'smsSentCount now reflects rows queued into the extract, not confirmed-delivered messages');
    }
}
