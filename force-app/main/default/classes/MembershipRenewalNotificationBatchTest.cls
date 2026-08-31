/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: execute() queries blng__Payment__c and blng__Invoice__c, so these
 * tests require the Billing managed package to be installed in the org
 * running them (see high-level-design.md §6 on validating blng field
 * names). The `rule` member is set directly via its @TestVisible modifier
 * to avoid depending on a deployed Renewal_Notification_Rule__mdt record.
 * As of the MOVEit file-handoff correction (see NotificationGatewayService
 * class header), execute() itself never calls out — only finish()'s
 * gateway.flush() does — so most of these tests no longer need an
 * HttpCalloutMock at all; testFinish_uploadsQueuedExtractFile below is the
 * one that does.
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
    static void testExecute_skipsWhenNoUsablePhone() {
        // Builds a minimal scope with no MobilePhone on the related
        // Contact and confirms the batch counts it as a "no cell" skip
        // rather than attempting a send — mirrors MD022EX's WS-NO-CELL-COUNT.
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Account acc = new Account(Name = 'Test Household');
        insert acc;
        Contact con = new Contact(FirstName = 'Jane', LastName = 'Doe', AccountId = acc.Id);
        insert con;

        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');
        batchInstance.rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'MD022EX', Requires_No_Payment_In_Transit__c = false,
                Requires_SMS_Consent__c = false, Requires_Amount_Due_Gt_Zero__c = false);

        // Constructed in memory only (not inserted) since Asset's custom
        // fields referenced by this scaffold are not deployed metadata —
        // see class header note.
        Asset a = new Asset(ContactId = con.Id, AccountId = acc.Id);

        Test.startTest();
        batchInstance.execute(null, new List<Asset>{ a });
        Test.stopTest();

        System.assertEquals(1, batchInstance.inputCount);
        System.assertEquals(1, batchInstance.noCellCount,
                'A Contact with no MobilePhone must be skipped and counted, matching MD022EX 2010');
        System.assertEquals(0, batchInstance.smsSentCount);
    }

    @isTest
    static void testExecute_queuesEligibleSmsRowThenFinishFlushesExtractFile() {
        // Confirms the queue-then-flush pattern end to end: execute()
        // appends a row without calling out, and finish() is the one place
        // that uploads the accumulated extract file to MOVEit (replacing
        // the legacy CLOSE OUTPUT-FILE + downstream pickup).
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Account acc = new Account(Name = 'Test Household');
        insert acc;
        Contact con = new Contact(FirstName = 'Jane', LastName = 'Doe', AccountId = acc.Id, MobilePhone = '5551234567');
        insert con;

        MembershipRenewalNotificationBatch batchInstance =
                new MembershipRenewalNotificationBatch('MD022EX');
        batchInstance.rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'MD022EX', Requires_No_Payment_In_Transit__c = false,
                Requires_SMS_Consent__c = false, Requires_Amount_Due_Gt_Zero__c = false);
        batchInstance.gateway = new NotificationGatewayService('MD022EX');

        Asset a = new Asset(ContactId = con.Id, AccountId = acc.Id);

        Test.startTest();
        batchInstance.execute(null, new List<Asset>{ a });
        batchInstance.finish(null);
        Test.stopTest();

        System.assertEquals(1, batchInstance.smsSentCount,
                'smsSentCount now reflects rows queued into the extract, not confirmed-delivered messages');
    }
}
