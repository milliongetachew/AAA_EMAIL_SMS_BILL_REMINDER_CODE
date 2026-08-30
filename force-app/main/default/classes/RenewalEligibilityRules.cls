/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §3 for the
 * Renewal_Notification_Rule__mdt field definitions this class reads.
 *
 * Encapsulates the eligibility logic shared by MD021EX, MD022EX, MD022ER,
 * MD022EC, MD022LP, and md022cc — each of those programs is a variation on
 * "compute a target date, run a DB2 cursor, then gate the row through a
 * chain of checks (payment-in-transit, cell phone on file, SMS consent,
 * amount due)". This class pushes the per-program differences into
 * Renewal_Notification_Rule__mdt records instead of duplicating the gate
 * chain once per legacy program.
 *
 * ASSUMPTION: custom object/field names below (Asset.Bill_Plan_Type__c,
 * Asset.Next_Bill_Event_Code__c, Asset.Campaign_Code__c,
 * Contact.SMS_Opt_In__c, blng__Payment__c.blng__Status__c,
 * blng__Invoice__c.blng__Balance__c) are illustrative and must be
 * validated against the org's actual schema — see HLD §6.
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

    /** Replaces MC556BR's SMS-consent authorization check. */
    public static Boolean hasSmsConsent(Contact c) {
        Object flag = c.get('SMS_Opt_In__c');
        return flag == true;
    }

    /**
     * Replaces MD022EC's campaign-code filter — see
     * docs/cobol-legacy/md022ec.md ("restricted to a growing whitelist of
     * marketing campaign codes"). Delimited-list membership check against
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
     * Replaces MD022EC/MD022LP's billing-event/bill-plan/bill-cycle filter:
     *   FK_MBR_BILL_EVENT IN (...) AND bill plan NOT IN ('AC','AH')
     *   AND bill cycle NOT IN ('IM','MA','NB')
     * (see docs/cobol-legacy/md022ec.md and md022lp.md, cursor LATEPAY).
     */
    public static Boolean matchesBillingEventFilter(Asset asset, Renewal_Notification_Rule__mdt rule) {
        String eventCode = (String) asset.get('Next_Bill_Event_Code__c');
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
        String billPlan = (String) asset.get('Bill_Plan_Type__c');
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
     * (already resolved via blng__Invoice__c) rather than called per-row
     * here, to keep this method callout-free and unit-testable.
     */
    public static EligibilityResult evaluate(Asset asset, Contact contact, Renewal_Notification_Rule__mdt rule,
            Boolean hasPaymentInTransit, Boolean hasUsablePhone, Decimal amountDue) {
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
        if (!matchesCampaignWhitelist((String) asset.get('Campaign_Code__c'), rule.Campaign_Codes__c)) {
            result.skipReason = 'CAMPAIGN_CODE_NOT_WHITELISTED';
            return result;
        }
        if (rule.Requires_Amount_Due_Gt_Zero__c == true && (amountDue == null || amountDue <= 0)) {
            result.skipReason = 'NO_AMOUNT_DUE';
            return result;
        }

        Boolean consented = hasSmsConsent(contact);
        result.smsEligible = (rule.Requires_SMS_Consent__c != true) || consented;
        result.pushEligible = rule.Requires_Push__c == true;

        if (!result.smsEligible && !result.pushEligible) {
            result.skipReason = 'NO_CONSENT';
        }
        return result;
    }
}
