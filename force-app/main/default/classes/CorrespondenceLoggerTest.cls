/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: flush() targets the custom object Correspondence__c, which does
 * not yet exist as deployed metadata (see high-level-design.md §2/§3).
 * These tests exercise the buffering contract (add/pendingCount/clear-on-
 * flush) that does not depend on that object existing; a real
 * implementation sprint should extend this with an assertion on inserted
 * row count once Correspondence__c is deployed.
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
        Id fakeContactId = null;

        Test.startTest();
        CorrespondenceLogger.Entry entry = new CorrespondenceLogger.Entry(
                fakeAssetId, fakeContactId, CorrespondenceLogger.Channel.EMAIL,
                '639', CorrespondenceLogger.Status.SUPPRESSED, 'MD134ML');
        Test.stopTest();

        System.assertEquals(CorrespondenceLogger.Channel.EMAIL, entry.channel);
        System.assertEquals('639', entry.correspondenceTypeCode);
        System.assertEquals(CorrespondenceLogger.Status.SUPPRESSED, entry.status);
        System.assertEquals('MD134ML', entry.sourceProgram);
    }
}
