/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: flush() targets the new custom object Correspondence_Log__c (not
 * yet deployed metadata) AND bulk-updates the existing
 * Asset.Correspondence__c multipicklist — see high-level-design.md §1/§2/§6
 * for the "two signals, deliberately used together" design decision. These
 * tests exercise the buffering contract (add/pendingCount/clear-on-flush)
 * and the pure isLegacyShapedCode() helper, neither of which depends on
 * Correspondence_Log__c existing; a real implementation sprint should
 * extend this with an assertion on inserted row count and Asset
 * multipicklist content once that object is deployed.
 */
@isTest
private class CorrespondenceLoggerTest {

    @isTest
    static void testAdd_incrementsPendingCount() {
        CorrespondenceLogger logger = new CorrespondenceLogger();

        Test.startTest();
        logger.add(null, null, CorrespondenceLogger.Channel.SMS, 'MD022EX',
                CorrespondenceLogger.Status.SENT, 'MD022EX');
        logger.add(null, null, CorrespondenceLogger.Channel.PUSH, 'MD022ER',
                CorrespondenceLogger.Status.SENT, 'MD022ER');
        Test.stopTest();

        System.assertEquals(2, logger.pendingCount(), 'Two queued entries should be reflected before flush');
    }

    @isTest
    static void testFlush_withNoEntries_returnsEmptyAndDoesNotThrow() {
        CorrespondenceLogger logger = new CorrespondenceLogger();

        Test.startTest();
        List<Database.SaveResult> results = logger.flush();
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Flushing an empty buffer should be a no-op, not a DML call');
        System.assertEquals(0, logger.pendingCount());
    }

    @isTest
    static void testEntryConstructor_capturesAllFields() {
        Id fakeAssetId = null;
        Id fakeAccountId = null;

        Test.startTest();
        CorrespondenceLogger.Entry entry = new CorrespondenceLogger.Entry(
                fakeAssetId, fakeAccountId, CorrespondenceLogger.Channel.EMAIL,
                '639', CorrespondenceLogger.Status.SUPPRESSED, 'MD134ML');
        Test.stopTest();

        System.assertEquals(CorrespondenceLogger.Channel.EMAIL, entry.channel);
        System.assertEquals('639', entry.correspondenceTypeCode);
        System.assertEquals(CorrespondenceLogger.Status.SUPPRESSED, entry.status);
        System.assertEquals('MD134ML', entry.sourceProgram);
    }

    @isTest
    static void testIsLegacyShapedCode_matchesThreeDigitCodesOnly() {
        // Asset.Correspondence__c's 216 values are 3-digit legacy codes
        // ('639','868','768','668','168', etc.); template/source codes
        // like 'MD022EX' or 'CARD_DECLINE' are not eligible for the
        // multipicklist dual-write — see class header.
        CorrespondenceLogger logger = new CorrespondenceLogger();

        Test.startTest();
        Boolean legacyCode = logger.isLegacyShapedCode('639');
        Boolean templateCode = logger.isLegacyShapedCode('CARD_DECLINE');
        Boolean blankCode = logger.isLegacyShapedCode(null);
        Boolean tooShort = logger.isLegacyShapedCode('68');
        Test.stopTest();

        System.assertEquals(true, legacyCode);
        System.assertEquals(false, templateCode);
        System.assertEquals(false, blankCode);
        System.assertEquals(false, tooShort);
    }
}
