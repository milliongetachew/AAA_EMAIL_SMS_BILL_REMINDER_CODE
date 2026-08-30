/**
 * Design scaffold — not compiled/tested production code.
 * Demonstrates the intended mocking pattern for NotificationGatewayService's
 * HTTP callouts (Named Credential "Notification_Gateway"). ASSUMPTION:
 * requires the Named Credential to exist in the target org for the
 * `callout:Notification_Gateway` endpoint prefix to resolve; the mock below
 * intercepts the HTTP call itself so no live callout occurs during tests.
 */
@isTest
private class NotificationGatewayServiceTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"messageId":"MOCK-123"}');
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
    static void testSendSms_success() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        NotificationGatewayService gateway = new NotificationGatewayService();

        Test.startTest();
        NotificationGatewayService.NotificationResult result =
                gateway.sendSms('+15551234567', 'MD022EX', new Map<String, Object>{ 'firstName' => 'Jane' });
        Test.stopTest();

        System.assertEquals(true, result.success, 'Expected a 2xx response to be treated as success');
        System.assertEquals('MOCK-123', result.providerMessageId);
    }

    @isTest
    static void testSendEmail_failureIsCapturedNotThrown() {
        Test.setMock(HttpCalloutMock.class, new FailureMock());
        NotificationGatewayService gateway = new NotificationGatewayService();

        Test.startTest();
        NotificationGatewayService.NotificationResult result =
                gateway.sendEmail('member@example.com', 'CARD_DECLINE', new Map<String, Object>());
        Test.stopTest();

        System.assertEquals(false, result.success, 'A 5xx response should be surfaced as a failed result, not an exception');
        System.assert(result.errorMessage.contains('500'), 'Error message should include the HTTP status code');
    }

    @isTest
    static void testSendPush_success() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        NotificationGatewayService gateway = new NotificationGatewayService();

        Test.startTest();
        NotificationGatewayService.NotificationResult result =
                gateway.sendPush('001000000000001AAA', 'MD022LP', new Map<String, Object>());
        Test.stopTest();

        System.assertEquals(true, result.success);
    }
}
