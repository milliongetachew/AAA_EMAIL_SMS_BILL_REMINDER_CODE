/**
 * Design scaffold — not compiled/tested production code.
 * Demonstrates the intended queue-then-flush pattern for
 * NotificationGatewayService: queueSms()/queuePush()/queueEmail() never
 * perform a callout (so they need no HTTP mock), and flush() performs at
 * most one callout per channel that has queued rows. ASSUMPTION: the mock
 * below intercepts the HTTP call itself, so it does not depend on the real
 * endpoint shape flush() ultimately calls — which, per the real two-stage
 * AFT/MOVEit job configuration (see
 * docs/salesforce-design/moveit-aft-reference.md and the class header on
 * NotificationGatewayService), is UNRESOLVED and unlikely to be a direct
 * MOVEit API call at all, since MOVEit only ever receives a file after a
 * separate, already-existing "Encrypted File Transfer" AFT job has
 * PGP-encrypted it.
 */
@isTest
private class NotificationGatewayServiceTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('OK');
            return res;
        }
    }

    private class FailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    @isTest
    static void testQueueSms_missingPhoneIsNotQueued() {
        NotificationGatewayService gateway = new NotificationGatewayService('MD022EX');

        Test.startTest();
        NotificationGatewayService.QueueResult result =
                gateway.queueSms(null, 'MD022EX', new Map<String, Object>{ 'firstName' => 'Jane' });
        Test.stopTest();

        System.assertEquals(false, result.queued, 'A blank destination must not be appended to the extract');
        System.assertEquals(0, gateway.pendingCount(NotificationGatewayService.Channel.SMS));
    }

    @isTest
    static void testQueueSms_appendsRowWithoutAnyCallout() {
        // No HttpCalloutMock is set here on purpose: queueSms() must never
        // perform a callout by itself, only flush() does.
        NotificationGatewayService gateway = new NotificationGatewayService('MD021EX');

        Test.startTest();
        NotificationGatewayService.QueueResult result =
                gateway.queueSms('+15551234567', 'MD021EX', new Map<String, Object>{ 'firstName' => 'Jane' });
        Test.stopTest();

        System.assertEquals(true, result.queued);
        System.assertEquals(1, gateway.pendingCount(NotificationGatewayService.Channel.SMS));
    }

    @isTest
    static void testFlush_noQueuedRowsProducesNoResultsAndNoCallout() {
        NotificationGatewayService gateway = new NotificationGatewayService('MD021EX');

        Test.startTest();
        List<NotificationGatewayService.FlushResult> results = gateway.flush();
        Test.stopTest();

        System.assertEquals(0, results.size(), 'flush() with nothing queued should not attempt any channel upload');
    }

    @isTest
    static void testFlush_uploadsOneFilePerChannelWithQueuedRows() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        NotificationGatewayService gateway = new NotificationGatewayService('MD021EX');
        gateway.queueSms('+15551234567', 'MD021EX', new Map<String, Object>{ 'firstName' => 'Jane' });
        gateway.queueSms('+15557654321', 'MD021EX', new Map<String, Object>{ 'firstName' => 'John' });
        gateway.queueEmail('jane@example.com', 'MD021EX', new Map<String, Object>{ 'firstName' => 'Jane' });

        Test.startTest();
        List<NotificationGatewayService.FlushResult> results = gateway.flush();
        Test.stopTest();

        System.assertEquals(2, results.size(),
                'Only SMS and EMAIL had queued rows, so PUSH must not produce an upload attempt');
        for (NotificationGatewayService.FlushResult result : results) {
            System.assertEquals(true, result.success, 'A 2xx MOVEit upload response should be treated as success');
            System.assert(String.isNotBlank(result.fileName), 'flush() must assign a file name per channel');
        }
        System.assertEquals(0, gateway.pendingCount(NotificationGatewayService.Channel.SMS),
                'flush() must clear buffered rows even on success');
    }

    @isTest
    static void testFlush_failureIsCapturedNotThrown() {
        Test.setMock(HttpCalloutMock.class, new FailureMock());
        NotificationGatewayService gateway = new NotificationGatewayService('MD572EM');
        gateway.queueEmail('member@example.com', 'CARD_DECLINE', new Map<String, Object>());

        Test.startTest();
        List<NotificationGatewayService.FlushResult> results = gateway.flush();
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success,
                'A 5xx response from the MOVEit upload should be surfaced as a failed result, not an exception');
        System.assert(results[0].errorMessage.contains('500'), 'Error message should include the HTTP status code');
    }

    @isTest
    static void testBuildFileBody_usesProgramSpecificDelimiter() {
        NotificationGatewayService gateway = new NotificationGatewayService('MD572EM');
        List<Map<String, Object>> rows = new List<Map<String, Object>>{
            new Map<String, Object>{ 'to' => 'a@example.com', 'templateCode' => 'CARD_DECLINE' }
        };

        Test.startTest();
        String body = gateway.buildFileBody(rows, ';');
        Test.stopTest();

        System.assert(body.startsWith('to;templateCode'), 'MD572EM used a semicolon-delimited legacy layout');
        System.assert(body.contains('a@example.com;CARD_DECLINE'));
    }
}
