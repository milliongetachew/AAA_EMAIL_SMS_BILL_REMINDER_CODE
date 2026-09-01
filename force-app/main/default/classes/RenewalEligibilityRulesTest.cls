/**
 * Design scaffold — not compiled/tested production code.
 * Renewal_Notification_Rule__mdt records are constructed in-memory (the
 * standard pattern for unit-testing Custom Metadata Type consumers,
 * since CMDT records cannot be inserted via DML in tests) rather than
 * queried, so these tests do not depend on any records being deployed.
 *
 * CORRECTED per data-dictionary-reference.md: evaluate()/hasSmsConsent()
 * now take an Account (Person Account) in place of the former Contact
 * parameter, and read Consent_for_SMS__c rather than the placeholder
 * Contact.SMS_Opt_In__c. evaluate() also accepts a bulk-preloaded
 * Map<String, Campaign_Code__c> in place of a single CMDT-only whitelist
 * check — see RenewalEligibilityRules class header.
 */
@isTest
private class RenewalEligibilityRulesTest {

    @isTest
    static void testComputeTargetDate_simpleOffset_matchesMD022EX() {
        // Replicates MD022EX 1300-CALC-TARGET-DATE:
        // WS-TARGET-DATE = WS-PROC-DATE + WS-SMS-DAYS DAYS
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Date_Formula__c = 'SIMPLE_OFFSET', Day_Offset__c = 13);
        Date processingDate = Date.newInstance(2026, 8, 30);

        Test.startTest();
        Date target = RenewalEligibilityRules.computeTargetDate(processingDate, rule);
        Test.stopTest();

        System.assertEquals(Date.newInstance(2026, 9, 12), target,
                'Simple offset should add Day_Offset__c days, matching MD021EX/MD022EX');
    }

    @isTest
    static void testComputeTargetDate_offsetPlusOneYear_matchesMD022EC() {
        // Replicates MD022EC/MD022LP/md022cc 1200-CALC-TARGET-DATE:
        // CHAR(DATE(:PROC-DATE-ISO) - :WS-INTER-DAYS DAYS + 1 YEAR)
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Date_Formula__c = 'OFFSET_PLUS_ONE_YEAR', Day_Offset__c = 5);
        Date processingDate = Date.newInstance(2026, 8, 30);

        Test.startTest();
        Date target = RenewalEligibilityRules.computeTargetDate(processingDate, rule);
        Test.stopTest();

        System.assertEquals(Date.newInstance(2027, 8, 25), target,
                'Offset-plus-one-year formula must be preserved verbatim per HLD §6, not simplified');
    }

    @isTest
    static void testMatchesCampaignWhitelist_blankRuleAllowsAny() {
        Test.startTest();
        Boolean matched = RenewalEligibilityRules.matchesCampaignWhitelist('9000068', null);
        Test.stopTest();

        System.assertEquals(true, matched, 'A blank whitelist means no restriction (MD021EX/MD022EX behavior)');
    }

    @isTest
    static void testMatchesCampaignWhitelist_matchesOneOfSeveral() {
        String whitelist = '9000068;9000083;9000087;9000088';

        Test.startTest();
        Boolean matchedInList = RenewalEligibilityRules.matchesCampaignWhitelist('9000083', whitelist);
        Boolean matchedNotInList = RenewalEligibilityRules.matchesCampaignWhitelist('9000099', whitelist);
        Test.stopTest();

        System.assertEquals(true, matchedInList, 'MD022EC-style whitelist should match a listed campaign code');
        System.assertEquals(false, matchedNotInList, 'Codes outside the whitelist must not match');
    }

    @isTest
    static void testMatchesBillingEventFilter_excludesAcAndAh() {
        // CORRECTED: bill-plan comparisons now read Asset.Bill_Plan__c
        // (real formula field) in place of the placeholder
        // Bill_Plan_Type__c — see RenewalEligibilityRules class header.
        // Next_Bill_Event_Code__c remains an unconfirmed placeholder (no
        // Billing/Payment object exists in this org — see HLD §1/§6).
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Billing_Event_Codes__c = '04;40;41;55;56;57;58;59',
                Exclude_Bill_Plan_Types__c = 'AC,AH');

        Asset eligibleAsset = new Asset();
        eligibleAsset.put('Next_Bill_Event_Code__c', '55');
        eligibleAsset.put('Bill_Plan__c', 'AM');

        Asset excludedAsset = new Asset();
        excludedAsset.put('Next_Bill_Event_Code__c', '55');
        excludedAsset.put('Bill_Plan__c', 'AC');

        Test.startTest();
        Boolean eligible = RenewalEligibilityRules.matchesBillingEventFilter(eligibleAsset, rule);
        Boolean excluded = RenewalEligibilityRules.matchesBillingEventFilter(excludedAsset, rule);
        Test.stopTest();

        System.assertEquals(true, eligible, 'AM bill plan with a qualifying event code should pass (MD022LP cursor)');
        System.assertEquals(false, excluded, 'AC bill plan must be excluded, matching MD022EC/MD022LP cursor filters');
    }

    @isTest
    static void testEvaluate_paymentInTransitSkipsRegardlessOfOtherFields() {
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Requires_No_Payment_In_Transit__c = true, Requires_SMS_Consent__c = true);
        Asset a = new Asset();
        Account personAccount = new Account(FirstName = 'Jane', LastName = 'Doe');

        Test.startTest();
        RenewalEligibilityRules.EligibilityResult result =
                RenewalEligibilityRules.evaluate(a, personAccount, rule, true, true, 100, null);
        Test.stopTest();

        System.assertEquals('PAYMENT_IN_TRANSIT', result.skipReason,
                'A member with a payment in transit must be skipped, matching MD021EX/MD022EX 2001-CHECK-PIT');
        System.assertEquals(false, result.smsEligible);
    }

    @isTest
    static void testEvaluate_noCellPhoneSkips() {
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt();
        Asset a = new Asset();
        Account personAccount = new Account();

        Test.startTest();
        RenewalEligibilityRules.EligibilityResult result =
                RenewalEligibilityRules.evaluate(a, personAccount, rule, false, false, 100, null);
        Test.stopTest();

        System.assertEquals('NO_CELL_PHONE', result.skipReason);
    }

    @isTest
    static void testEvaluate_md022cc_sendsSmsWithoutConsent() {
        // Replicates md022cc's deliberate removal of the SMS consent gate
        // (MEM-482325) — Requires_SMS_Consent__c = false must still result
        // in an SMS-eligible outcome even though the Person Account has not
        // opted in (Account.Consent_for_SMS__c = false).
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'md022cc', Requires_SMS_Consent__c = false, Requires_Push__c = true);
        Asset a = new Asset();
        Account personAccount = new Account();
        personAccount.put('Consent_for_SMS__c', false);

        Test.startTest();
        RenewalEligibilityRules.EligibilityResult result =
                RenewalEligibilityRules.evaluate(a, personAccount, rule, false, true, null, null);
        Test.stopTest();

        System.assertEquals(true, result.smsEligible,
                'md022cc must send SMS even without consent — a deliberate, compliance-relevant difference (MEM-482325)');
        System.assertEquals(true, result.pushEligible);
        System.assertEquals(null, result.skipReason);
    }

    @isTest
    static void testEvaluate_consentRequiredAndMissing_skipsSmsOnly() {
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Source_Program__c = 'MD022EX', Requires_SMS_Consent__c = true, Requires_Push__c = false);
        Asset a = new Asset();
        Account personAccount = new Account();
        personAccount.put('Consent_for_SMS__c', false);

        Test.startTest();
        RenewalEligibilityRules.EligibilityResult result =
                RenewalEligibilityRules.evaluate(a, personAccount, rule, false, true, 50, null);
        Test.stopTest();

        System.assertEquals(false, result.smsEligible);
        System.assertEquals('NO_CONSENT', result.skipReason,
                'MD022EX requires MC556BR consent; missing consent with no Push fallback should skip entirely');
    }

    @isTest
    static void testEvaluate_amountDueRequiredAndZero_skips() {
        Renewal_Notification_Rule__mdt rule = new Renewal_Notification_Rule__mdt(
                Requires_Amount_Due_Gt_Zero__c = true, Requires_SMS_Consent__c = false);
        Asset a = new Asset();
        Account personAccount = new Account();

        Test.startTest();
        RenewalEligibilityRules.EligibilityResult result =
                RenewalEligibilityRules.evaluate(a, personAccount, rule, false, true, 0, null);
        Test.stopTest();

        System.assertEquals('NO_AMOUNT_DUE', result.skipReason,
                'MD022EX/MD022ER gate on MD610BR returning a nonzero amount due');
    }

    @isTest
    static void testHasSmsConsent_readsAccountConsentField() {
        // CORRECTED: SMS consent is Account.Consent_for_SMS__c on the
        // Person Account, not a Contact field — see class header.
        Account consented = new Account();
        consented.put('Consent_for_SMS__c', true);
        Account notConsented = new Account();
        notConsented.put('Consent_for_SMS__c', false);

        Test.startTest();
        Boolean consentedResult = RenewalEligibilityRules.hasSmsConsent(consented);
        Boolean notConsentedResult = RenewalEligibilityRules.hasSmsConsent(notConsented);
        Boolean nullAccountResult = RenewalEligibilityRules.hasSmsConsent(null);
        Test.stopTest();

        System.assertEquals(true, consentedResult);
        System.assertEquals(false, notConsentedResult);
        System.assertEquals(false, nullAccountResult, 'A null Person Account must not be treated as consented');
    }

    @isTest
    static void testIsCampaignCodeActive_nullMapMeansNoRestriction() {
        Test.startTest();
        Boolean result = RenewalEligibilityRules.isCampaignCodeActive('PO65%', null);
        Test.stopTest();

        System.assertEquals(true, result,
                'A null activeCodesByName map means the real-object check was not evaluated (data unavailable), not a restriction');
    }

    @isTest
    static void testIsCampaignCodeActive_blankCodeWithMapIsNotActive() {
        Map<String, Campaign_Code__c> activeCodes = new Map<String, Campaign_Code__c>{
            'PO65%' => new Campaign_Code__c(Campaign_Code_Name__c = 'PO65%')
        };

        Test.startTest();
        Boolean matched = RenewalEligibilityRules.isCampaignCodeActive('PO65%', activeCodes);
        Boolean notMatched = RenewalEligibilityRules.isCampaignCodeActive('NOTFOUND', activeCodes);
        Boolean blankCode = RenewalEligibilityRules.isCampaignCodeActive(null, activeCodes);
        Test.stopTest();

        System.assertEquals(true, matched, 'A code present in the bulk-preloaded active map should match');
        System.assertEquals(false, notMatched, 'A code absent from the active map should not match');
        System.assertEquals(false, blankCode,
                'A blank campaign code with a real map supplied should be treated as no code on file, not a pass');
    }
}
