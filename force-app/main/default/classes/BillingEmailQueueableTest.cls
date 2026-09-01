/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: BillingEmailQueueable queries Asset custom fields (Letter_Code__c —
 * still unresolved, see class header) plus the real, confirmed fields
 * Club__c, Bill_Plan__c, Member_Number__c, and the placeholder object
 * Asset_Change_Event__c (not covered by the data-dictionary audit). These
 * tests exercise the class's @TestVisible helper methods directly (which do
 * not require those objects) plus a smoke test of the full execute() path.
 *
 * CORRECTED per data-dictionary-reference.md: members are Person Accounts,
 * not a separate Contact — Asset.AccountId points directly at the Person
 * Account (PersonEmail/FirstName/LastName), not a Contact lookup.
 */
@isTest
private class BillingEmailQueueableTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"messageId":"MOCK-139"}');
            return res;
        }
    }

    @isTest
    static void testResolveCorrespondenceType_returnsLetterCode() {
        // Stand-in for MD607BR (B0100-WILL-EMAIL-BE-PRODUCED) — see class
        // header comment on resolveCorrespondenceType's placeholder logic.
        Asset a = new Asset();
        a.put('Letter_Code__c', '139');
        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        String correspondenceType = queueable.resolveCorrespondenceType(a);
        Test.stopTest();

        System.assertEquals('139', correspondenceType);
    }

    @isTest
    static void testBuildEmailPayload_mapsCoreFields() {
        Account personAccount = new Account(LastName = 'Doe', FirstName = 'Jane', PersonEmail = 'jane@example.com');
        insert personAccount;

        Asset a = new Asset(AccountId = personAccount.Id);
        a.put('Club__c', '001');
        a.put('Bill_Plan__c', 'MP');
        a.put('Member_Number__c', '12345678');

        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        Map<String, Object> payload = queueable.buildEmailPayload(a);
        Test.stopTest();

        System.assertEquals('001', payload.get('clubCode'));
        System.assertEquals('MP', payload.get('billPlan'));
        System.assertEquals('12345678', payload.get('membershipNumber'));
    }

    @isTest
    static void testGetWebSelfServiceSuppressedAssets_emptyInputReturnsEmptySet() {
        // Empty input should short-circuit before querying
        // Asset_Change_Event__c (the INC943560 web-origination check),
        // matching B0200-DO-NOT-SEND-EMAIL's guard for non-letter-139 rows.
        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        Set<Id> suppressed = queueable.getWebSelfServiceSuppressedAssets(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, suppressed.size());
    }
}
