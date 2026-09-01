/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §3 for the
 * Renewal_Notification_Rule__mdt field definitions this class reads, and
 * docs/salesforce-design/data-dictionary-reference.md for the real,
 * field-verified schema this class now targets.
 *
 * Encapsulates the eligibility logic shared by MD021EX, MD022EX, MD022ER,
 * MD022EC, MD022LP, and md022cc — each of those programs is a variation on
 * "compute a target date, run a DB2 cursor, then gate the row through a
 * chain of checks (payment-in-transit, cell phone on file, SMS consent,
 * amount due)". This class pushes the per-program differences into
 * Renewal_Notification_Rule__mdt records instead of duplicating the gate
 * chain once per legacy program.
 *
 * CORRECTED per the data-dictionary audit (see HLD §6 "Person Account
 * correction" and "Campaign_Code__c ... zero automation"):
 *  - The SMS-consent check now reads Account.Consent_for_SMS__c (real,
 *    confirmed field) on the Person Account — NOT Contact.SMS_Opt_In__c,
 *    which never existed in this org; the member IS the Account.
 *  - Campaign-code eligibility now queries the real Campaign_Code__c
 *    object (isCampaignCodeActive()) instead of only a CMDT-defined
 *    whitelist string. That object has ZERO automation today, so this is
 *    the first thing to actually enforce it, not a replication of
 *    existing behavior.
 *  - matchesBillingEventFilter() reads Asset.Bill_Plan__c (real formula
 *    field) in place of the placeholder Bill_Plan_Type__c, but its
 *    Next_Bill_Event_Code__c input remains UNRESOLVED — no Billing/
 *    Payment object of any kind was found in the data-dictionary audit,
 *    so there is no confirmed field to source a billing-event code from
 *    at all (not just an unconfirmed field name). See HLD §1/§6
 *    "Billing/Payment gap".
 *  - hasPaymentInTransit() still queries blng__Payment__c, kept as an
 *    explicitly-flagged, UNCHANGED placeholder — do not swap in a
 *    different guessed object/field name; this remains a genuinely open
 *    question pending a separate billing/payment investigation.
 */
public with sharing class RenewalEligibilityRules {

    public class EligibilityResult {
        public Boolean smsEligible = false;
        public Boolean pushEligible = false;
        public String skipReason;
    }

    /**
     * Replaces MD022EX's 1200-GET-NO-DAYS / MD022EC's SYSIN interval read /
     * MD021EX's hard-coded 13-day literal — all folded into
     * Renewal_Notification_Rule__mdt.Day_Offset__c, selected by
     * Source_Program__c.
     */
    public static List<Renewal_Notification_Rule__mdt> getActiveRules() {
        return [
            SELECT Source_Program__c, Club_Code__c, Campaign_Codes__c, Billing_Event_Codes__c,
                   Exclude_Bill_Plan_Types__c, Exclude_Bill_Cycles__c, Day_Offset__c,
                   Date_Formula__c, Requires_SMS_Consent__c, Requires_Push__c,
                   Requires_Amount_Due_Gt_Zero__c, Requires_No_Payment_In_Transit__c,
                   Bill_Plan_Filter__c
            FROM Renewal_Notification_Rule__mdt
            WHERE Active__c = true
        ];
    }

    /**
     * Replaces the two distinct date-math patterns found in source:
     *  - SIMPLE_OFFSET: MD021EX/MD022EX/MD022ER's "processing date + N days"
     *    (MD021EX: 1005-GET-PROC-DATE; MD022EX: 1300-CALC-TARGET-DATE)
     *  - OFFSET_PLUS_ONE_YEAR: MD022EC/MD022LP/md022cc's
     *    "(processing date - N days) + 1 YEAR" formula (1200-CALC-TARGET-DATE
     *    in each). Preserved verbatim per HLD §6 — do not "fix" without a
     *    business decision.
     */
    public static Date computeTargetDate(Date processingDate, Renewal_Notification_Rule__mdt rule) {
        Integer offset = rule.Day_Offset__c == null ? 0 : (Integer) rule.Day_Offset__c;
        if (rule.Date_Formula__c == 'OFFSET_PLUS_ONE_YEAR') {
            return processingDate.addDays(-offset).addYears(1);
        }
        // SIMPLE_OFFSET and FIXED_MINUS_77 (the latter is a no-op here —
        // MD022ZA's -77 day window is applied upstream; see HLD §5/§6)
        return processingDate.addDays(offset);
    }

    /**
     * Replaces FN435BT (payment-in-transit check): a payment record in a
     * Processing/Pending state against the member's billing account is
     * treated as "in transit" and suppresses the reminder, mirroring
     * MD021EX's 2001-CHECK-PIT / 2005-CHECK-PIT-DETAIL summation of
     * FIN435-O-PAYMNT-STATUS = 'PIT '.
     */
    public static Boolean hasPaymentInTransit(Id billingAccountId, Map<Id, List<SObject>> paymentsByBillingAccount) {
        if (billingAccountId == null) {
            return false;
        }
        List<SObject> payments = paymentsByBillingAccount.get(billingAccountId);
        if (payments == null) {
            return false;
        }
        for (SObject p : payments) {
            String status = (String) p.get('blng__Status__c');
            if (status == 'Processing' || status == 'Pending') {
                return true;
            }
        }
        return false;
    }

    /**
     * Replaces MC556BR's SMS-consent authorization check.
     * CORRECTED: reads Account.Consent_for_SMS__c (real, confirmed field)
     * on the Person Account — the member IS the Account in this org's
     * model, so `personAccount` here is the same record as `asset.AccountId`
     * resolves to, not a related Contact.
     */
    public static Boolean hasSmsConsent(Account personAccount) {
        if (personAccount == null) {
            return false;
        }
        Object flag = personAccount.get('Consent_for_SMS__c');
        return flag == true;
    }

    /**
     * Rule-level, SUPPLEMENTARY campaign-code restriction — layered on top
     * of (not a replacement for) isCampaignCodeActive()/
     * getActiveCampaignCodesByName() below, which query the real
     * Campaign_Code__c object. Use this only for a rule-specific narrowing
     * (e.g. "this legacy program variant only ever fired for these
     * codes"); it is NOT the source of truth for whether a code is
     * currently active/eligible. Delimited-list membership check against
     * Renewal_Notification_Rule__mdt.Campaign_Codes__c; a blank list means
     * "no restriction" (MD021EX/MD022EX/MD022ER/MD022LP/md022cc behavior).
     */
    public static Boolean matchesCampaignWhitelist(String assetCampaignCode, String ruleCampaignCodes) {
        if (String.isBlank(ruleCampaignCodes)) {
            return true;
        }
        if (String.isBlank(assetCampaignCode)) {
            return false;
        }
        for (String code : ruleCampaignCodes.split(';')) {
            if (code.trim().equalsIgnoreCase(assetCampaignCode.trim())) {
                return true;
            }
        }
        return false;
    }

    /**
     * Bulk-fetches the real Campaign_Code__c records that are currently
     * active for a club, keyed by Campaign_Code_Name__c (the human-facing
     * code stored in OrderItem.Campaign_Code_Applied__c — NOT the record
     * Id). Replaces MD022EC's hard-coded campaign-code whitelist with the
     * real object: Club_Code__c match, Status__c = 'Active', and asOfDate
     * between Effective_Date__c/Expiration_Date__c. Call once per batch
     * scope (bulk-safe), not per row — see RenewalEligibilityRulesTest for
     * usage.
     *
     * IMPORTANT: Campaign_Code__c/Campaign_Action__c have ZERO automation
     * in this org today (no flow, trigger, or validation rule enforces
     * them) — this migration is the FIRST thing to actually apply these
     * eligibility rules at the platform level, not a replication of
     * existing enforcement. Confirm with the business that this is an
     * intended behavior change before relying on it to gate sends.
     */
    public static Map<String, Campaign_Code__c> getActiveCampaignCodesByName(String clubCode, Date asOfDate) {
        Map<String, Campaign_Code__c> result = new Map<String, Campaign_Code__c>();
        for (Campaign_Code__c cc : [
            SELECT Campaign_Code_Name__c, Club_Code__c, Status__c, Effective_Date__c, Expiration_Date__c,
                   Pricing_Type__c, AutoPay_Required__c, Billing_Type__c
            FROM Campaign_Code__c
            WHERE Club_Code__c = :clubCode
              AND Status__c = 'Active'
              AND Effective_Date__c <= :asOfDate
              AND Expiration_Date__c >= :asOfDate
        ]) {
            result.put(cc.Campaign_Code_Name__c, cc);
        }
        return result;
    }

    /**
     * O(1) membership check against a bulk-preloaded active-code map (see
     * getActiveCampaignCodesByName()) — kept query-free so it is safe to
     * call once per row inside a batch execute() loop.
     *
     * GAP (see HLD §6): Asset does not carry a confirmed campaign-code
     * identifier field forward from the originating Order/OrderItem in
     * this org's schema — only campaign *pricing* fields propagate via
     * RT_AssetActionSource_Payment_Method_Propagation, not the code name
     * itself. Until that lineage is resolved (new propagated field, or a
     * traversal through AssetActionSource/OrderItem), callers will
     * typically not have a non-blank campaignCodeName to pass in here. A
     * null/blank campaignCodeName with a non-null activeCodesByName map is
     * treated as "no code on file" rather than an automatic pass — callers
     * that want "no restriction when data is unavailable" should pass
     * activeCodesByName = null instead.
     */
    public static Boolean isCampaignCodeActive(String campaignCodeName, Map<String, Campaign_Code__c> activeCodesByName) {
        if (activeCodesByName == null) {
            return true;
        }
        if (String.isBlank(campaignCodeName)) {
            return false;
        }
        return activeCodesByName.containsKey(campaignCodeName.trim());
    }

    /**
     * Replaces MD022EC/MD022LP's billing-event/bill-plan/bill-cycle filter:
     *   FK_MBR_BILL_EVENT IN (...) AND bill plan NOT IN ('AC','AH')
     *   AND bill cycle NOT IN ('IM','MA','NB')
     * (see docs/cobol-legacy/md022ec.md and md022lp.md, cursor LATEPAY).
     *
     * CORRECTED: bill-plan comparisons now read Asset.Bill_Plan__c (real
     * formula field, e.g. 'AC' for Annual+Autopay+Card) in place of the
     * placeholder Bill_Plan_Type__c. The billing-event-code side
     * (Next_Bill_Event_Code__c) remains fully UNRESOLVED — no Billing/
     * Payment object of any kind exists in the data-dictionary audit, so
     * there is currently no confirmed field anywhere in the org to source
     * a billing-event code from. See HLD §1/§6 "Billing/Payment gap".
     */
    public static Boolean matchesBillingEventFilter(Asset asset, Renewal_Notification_Rule__mdt rule) {
        String eventCode = (String) asset.get('Next_Bill_Event_Code__c'); // UNRESOLVED — see method header
        if (String.isNotBlank(rule.Billing_Event_Codes__c)) {
            Boolean matched = false;
            for (String code : rule.Billing_Event_Codes__c.split(';')) {
                if (code.trim().equals(eventCode)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                return false;
            }
        }
        String billPlan = (String) asset.get('Bill_Plan__c');
        if (String.isNotBlank(rule.Exclude_Bill_Plan_Types__c)
                && rule.Exclude_Bill_Plan_Types__c.split(',').contains(billPlan)) {
            return false;
        }
        return true;
    }

    /**
     * Top-level gate chain, mirroring 2000-PROCESS-CURSOR's sequential
     * IF/ELSE skip-and-count structure shared across MD021EX/MD022EX/
     * MD022ER/MD022EC/MD022LP/md022cc. Amount-due lookup is passed in
     * (already resolved against whatever the org's confirmed billing/
     * payment source turns out to be — see HLD §1/§6 "Billing/Payment
     * gap") rather than called per-row here, to keep this method
     * callout-free and unit-testable.
     *
     * CORRECTED: `personAccount` replaces the former `Contact contact`
     * parameter — the member is a Person Account in this org, not a
     * related Contact (see HLD §6 "Person Account correction").
     * `activeCampaignCodesByName` is the bulk-preloaded real
     * Campaign_Code__c map from getActiveCampaignCodesByName(); pass null
     * to skip the real-object campaign check entirely (e.g. when the
     * Asset-side campaign-code field lineage gap, see
     * isCampaignCodeActive()'s header, hasn't been resolved yet).
     */
    public static EligibilityResult evaluate(Asset asset, Account personAccount, Renewal_Notification_Rule__mdt rule,
            Boolean hasPaymentInTransit, Boolean hasUsablePhone, Decimal amountDue,
            Map<String, Campaign_Code__c> activeCampaignCodesByName) {
        EligibilityResult result = new EligibilityResult();

        if (rule.Requires_No_Payment_In_Transit__c == true && hasPaymentInTransit) {
            result.skipReason = 'PAYMENT_IN_TRANSIT';
            return result;
        }
        if (!hasUsablePhone) {
            result.skipReason = 'NO_CELL_PHONE';
            return result;
        }
        if (!matchesBillingEventFilter(asset, rule)) {
            result.skipReason = 'BILLING_EVENT_FILTER';
            return result;
        }
        String assetCampaignCode = (String) asset.get('Campaign_Code__c'); // see isCampaignCodeActive() header — GAP
        if (!matchesCampaignWhitelist(assetCampaignCode, rule.Campaign_Codes__c)
                || !isCampaignCodeActive(assetCampaignCode, activeCampaignCodesByName)) {
            result.skipReason = 'CAMPAIGN_CODE_NOT_WHITELISTED';
            return result;
        }
        if (rule.Requires_Amount_Due_Gt_Zero__c == true && (amountDue == null || amountDue <= 0)) {
            result.skipReason = 'NO_AMOUNT_DUE';
            return result;
        }

        Boolean consented = hasSmsConsent(personAccount);
        result.smsEligible = (rule.Requires_SMS_Consent__c != true) || consented;
        result.pushEligible = rule.Requires_Push__c == true;

        if (!result.smsEligible && !result.pushEligible) {
            result.skipReason = 'NO_CONSENT';
        }
        return result;
    }
}
