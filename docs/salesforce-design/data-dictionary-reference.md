# ACE Data Dictionary Reference (Real Org)

Source: `ACE_DataDictionaryV2.xlsx`, supplied by the user 2026-08-31. This is a
**field-level audit of an existing Salesforce org** — not a design proposal.
Every field below is a real, currently-deployed field, cross-checked against
live automation (flows, Apex, formulas) and in several cases against actual
record counts. Confidence levels ("Confirmed" / "Business confirmed" /
"Inferred" / "NEEDS REVIEW" / "NEEDS INPUT") are carried over from the
source workbook.

**This supersedes every `blng__`/`SBQQ` reference in `high-level-design.md`
and the Apex scaffold.** The org uses native Salesforce Revenue Lifecycle
Management (standard `Order`/`OrderItem`/`Asset`, assetized via the
`revenue_o2aflows` managed package's Order-to-Asset flow) — not the older
CPQ (`SBQQ`) or Billing (`blng`) managed packages. No Billing/Payment object
appears anywhere in this data dictionary (see "Known gap" at the end).

## Object inventory (per the workbook's Summary tab)

| Object | Total fields | Custom fields | Formula fields | Fields touched by automation |
|---|---|---|---|---|
| Order | 68 | 7 | 0 | 17 |
| OrderItem | 85 | 24 | 1 | 24 |
| Asset | 88 | 28 | 3 | 41 |
| Account (business) | 95 | 38 | 5 | 10 |
| Person Account | 64 | 17 | 0 | 0 |
| Campaign_Code__c | 26 | 15 | 0 | 15 |
| Campaign_Action__c | 21 | 11 | 0 | 11 |

## Order (custom fields only — standard fields omitted, all platform-default)

| Field | Type | Purpose | Automation |
|---|---|---|---|
| `Auto_Pay_Discount_Amount__c` | currency | Order-level autopay discount. On the one traced order the discount actually appears as a line-level -5 adjustment instead. | none confirmed |
| `Autopay__c` | boolean | Autopay enrollment; blocks save if false when a Term-Based Monthly line is present; cascades to `OrderItem.Autopay__c`. | `RTF_Order_Payment_Restriction_Flow` (blocks save, active); a second flow meant to bulk-set this is **OBSOLETE — does not run** |
| `AutoPay_Discount_Eligibility_Date__c` / `AutoPay_Opt_Out_Date__c` | date | Mirrored on OrderItem and Asset. | — |
| `Campaign_Code__c` | reference → `Campaign_Code__c` | Drives promotional pricing on the order. | — |
| `Channel__c` | picklist (Web, Call Center, Branch, Partner, All) | Sales channel of origin. | — |
| `Payment_Method__c` | picklist (Credit Card, Debit Card, ACH/Checking, Check) | Blocks save when a monthly line pairs with ACH or Check. | `RTF_Order_Payment_Restriction_Flow` |

**Standard fields worth calling out:**
- `Status` (Draft/Activated) is the lifecycle gate — moving to Activated triggers assetization, billing-schedule creation, and both blocking guardrails.
- `Type` (Add/Amend/Renewal) is meant to derive from `OriginalActionType`, but the flow that would set it (`Set_Order_Type`) is **DRAFT — never activated**, yet live records **are** populated — something else (platform-internal) is setting it.
- `OriginalActionType` (Add/Amend/Cancel/No Change/Renew/Transfer) is stamped by the Revenue Cloud `initiateAmendment`/`initiateRenewal` invocable Apex, called from the Amend-Renew-and-Cancel screen flow. Blank on new business.
- `Pricebook2Id` is hardcoded by a flow to a single Pricebook (`01s8X000001YD4KQAW`) — effectively a constant in this org.
- Every `Billing*`/`Shipping*` address-copy-down flow (`Set_Order_Type` triggered) is **DRAFT — never activated**.
- `Maintain_Only_One_Membership_On_Account` reads `AccountId`, `Type`, and `Asset.CurrentQuantity` to block activation of a second membership order on a household that already has one (with an Amend/Renewal exemption via `Type`).

## OrderItem (custom fields only)

| Field | Type | Purpose | Automation |
|---|---|---|---|
| `Autopay__c` | boolean | Copied down from `Order.Autopay__c` on line creation. | `Set_Order_Product_Description_From_Product` (active) |
| `Billing_Frequency__c` | picklist (Annual, Monthly, One-time) | Drives the date cascade (One-time excluded) and the regional price match. | — |
| `Campaign_Code_Applied__c` | string | **Text** record of which campaign code was applied — stores the code **name**, not an Id. | — |
| `Campaign_Discount_Amount__c` / `_Percent__c` / `Campaign_Set_Price__c` / `Campaign_Unit_Price__c` | currency/percent | Captured campaign pricing. Intended source is `Campaign_Action__c`, but that object has **no automation** — these are not actually populated by the platform today. | none |
| `Club_Code__c` | string | AAA club identifier — first key in the regional pricing lookup. **Reaches `AssetActionSource` but has no matching field on `Asset`.** | `Update_OrderItem_Prices` (regional gate) |
| `Created_By_Campaign__c` / `Next_Year_Campaign_Code__c` | reference → `Campaign_Code__c` | Attribution and step-deal year-two pricing. `Next_Year_Campaign_Code__c` is **null on every campaign in the org today**. | — |
| `Customer_Unit_Price__c` | currency | Price actually charged after all adjustments (54 on the traced line, from a 59 list price less a 5 autopay adjustment). | — |
| `Payment_Method__c` | string (formula) | `TEXT(Order.Payment_Method__c)` — always current. | Formula |
| `Region__c` | string | Second key in the regional pricing lookup. | `Update_OrderItem_Prices` |
| `Role_Code__c` / `Role_Type__c` | string | Member's position/slot within the membership. | — |
| `Tier__c` | string | The tier **selected** during configuration (input); `Asset.Membership_Tier__c` is the derived output. | — |
| `Total_Price__c` | currency | Carried through unchanged to `Asset.Total_Price__c`. | — |

**Standard fields worth calling out:**
- `EndDate` = `Order.EffectiveDate + 364 days` (a 1-year membership term), set by `Set_Order_Product_Start_and_End_Dates`, gated to `Product2Id = 01tdy00000rysTwAAI` (the Membership product).
- `ParentOrderItemId` groups bundle children under the Membership line — **this hierarchy is lost at assetization** (not carried to the Asset).
- `UnitPrice` gets overwritten by the regional-pricing flow (`Update_OrderItem_Prices`) for club 252, or club 215 outside region 02 — a hardcoded club/region gate.
- `ListPrice`/`NetUnitPrice`/`NetTotalPrice`/`TotalAdjustmentAmount`/pricing fields are set by the platform's own Revenue Cloud pricing engine, not custom automation.

## Asset (custom fields only)

| Field | Type | Purpose | Automation / data-quality note |
|---|---|---|---|
| `Autopay__c`, `Billing_Frequency__c`, `Payment_Method__c`, `Customer_Unit_Price__c`, `List_Price__c`, `Net_Unit_Price__c`, `Prorate_Multiplier__c`, `Prorated_List_Price__c`, `Tax__c`, `Total_Price__c`, `Campaign_Discount_Amount__c`/`_Percent__c`, `Campaign_Set_Price__c`, `Campaign_Unit_Price__c` | various | All copied up from `AssetActionSource` by **`RT_AssetActionSource_Payment_Method_Propagation`** — the **only** custom hop carrying transaction values onto the Asset. Trigger is on `AssetActionSource`, not `Asset`. Also pushed back down by `RT_Asset_Fields_Propagation` when edited on the Asset (non-deterministic target if the asset has multiple lifecycle actions). | Active |
| `Bill_Plan__c` | string, **formula** | Derives a bill-plan code (`AC` observed for Annual + Autopay + Card) from `Billing_Frequency__c` + `Payment_Method__c` + `Autopay__c`. | Formula — always current |
| `Club__c` | string, formula | `TEXT(Account.Club_Code__c)` — always current and correct. | Formula |
| `CLUB_CODE__c` | picklist | Meant to be a stored copy of the Account club code (duplicating `Club__c`). | **NEVER FIRES — verified 0 of 190 Assets populated.** The before-save flow tries a parent traversal (`$Record.Account.Club_Code__c`) that isn't available in before-insert context. |
| `Correspondence__c` | **multipicklist, 216 values** | Three-digit correspondence codes used within the ACE membership system to trigger specific printed messages accompanying membership cards and bills. | No automation writes it in the reviewed flows — **this is an existing field holding the same kind of codes the legacy COBOL correspondence-type codes (`'639'`, `'868'`, `'768'`, `'668'`, `'168'` etc.) represent**, but as a multipicklist it is not a timestamped log — see "Design implication" below. |
| `Member_Number__c` | string, len 8 | Membership number, held on the `ProductCode = '60'` parent asset. | Apex `Generate_Membership_Number` → `RVNMembershipNo`, after-save Create+Update, entry: `ProductCode='60' AND Member_Number__c blank AND AccountId not null`. **PARTIAL — verified 21 of 40 Membership assets still blank (53% miss).** |
| `Membership_Price__c` | currency | **NEEDS REVIEW — business said "let's omit this field."** Not populated on any traced asset; do not design around it. |
| `Membership_Tier__c` | picklist (Classic/Plus/Premier) | Derived by **substring-matching sibling Asset NAMEs** (priority Premier > Plus > Classic) rather than from a product attribute. | `Account_Membership_Tier_From_Assets` (active but fragile/name-matched) |
| `RV_Motorcyle_Add_On__c` | boolean | True when any sibling asset name contains `'RV'`. Same fragile name-matching. | Active — fragile |
| `Special_Handling__c` | picklist, 18 values | Legacy AAA special-handling codes: donor billing, business/group memberships, NSF ACH, review-notes flags, dual membership/secret shopper/misconduct, etc. | — |
| `SpecialHandlingObj__c` | string | **NEEDS REVIEW — business said "remove this as well."** Looks like migration staging residue. |
| `Unpaid__c` | boolean, default True | Payment state; when set false on an Impaired asset, `Set_Asset_Status_to_Active_if_Unpaid_False` should move it to Active. | See `Status` note below — this path is currently unreachable. |

**Standard fields worth calling out:**
- `AccountId`, `AssetLevel`, `CurrentAmount`, `CurrentLifecycleEndDate`, `CurrentMrr`, `CurrentQuantity`, `HasLifecycleManagement`, `LifecycleEndDate`/`LifecycleStartDate`, `Name`, `Product2Id`, `ProductCode`, `ProductDescription`, `RenewalTerm(Unit)`, `RootAssetId`, `TotalLifecycleAmount` are **all** set at assetization by the platform-internal `revenue_o2aflows__o2aFlow` (async, after-commit, fires when an `Order.Status` becomes `Activated` and a `RevenueLifecycleManagement` `AppUsageAssignment` exists). Not independently retrievable — behavior is derived only from the records it produces.
- `CurrentQuantity`: the Membership **parent** asset sits at 0 and acts as a container; component assets hold 1. Tier logic filters on `> 0`.
- `ProductCode`: `'60'` = the Membership parent asset (entry criterion for membership-number generation); `'01'` and `'80'` seen on component assets.
- `Status` (Active/Grace Period/Lapsed/Suspended/Cancelled/Salvage/Deceased/Transferred Out/Impaired) — **null on 184 of 190 Assets (97%) — verified.** This breaks `Set_Asset_Status_to_Active_if_Unpaid_False` (its trigger path is unreachable since no Asset is ever `Impaired`) and neuters `Maintain_Only_One_Membership_On_Account`'s Active/Grace/Suspended/Salvage filter.

## Account — business fields (custom fields only; Person Account fields are separate, below)

| Field | Type | Purpose | Notes |
|---|---|---|---|
| `Club_Code__c` | picklist, 9 values | AAA club identifier — **the real, authoritative source**, feeding `Asset.Club__c`, the broken `Asset.CLUB_CODE__c` flow, and the regional pricing lookup. Read-only source (nothing writes it via automation). |
| `Consent_for_SMS__c` | boolean | SMS marketing consent — **this is the real field for the legacy `MC556BR` SMS-consent check**, replacing the placeholder `Contact.SMS_Opt_In__c` guessed at in the original HLD. |
| `Member_Number__c` | string, len 40 | Household membership number, assigned by the same `RVNMembershipNo` Apex, keyed on `accountIds`, invoked from the Asset-side `Generate_Membership_Number` flow. **PARTIAL** (same underlying gap as the Asset field). |
| `Member_Type__c` | picklist (Primary Member / Associate Member / Dependent Member / Donor-External Payer / MSO-Corporate Payer) | Household role. **Enforced**: only one Primary Member per household, and the order's Decision Maker must be that Primary Member, via `RTF_Validate_Primary_Member_on_Account` (before-save, validation-only — does not write). |
| `Membership_Expiration_Date__c` | date | Denormalized copy of the membership term end, for reporting/service screens. |
| `Membership_Number_Display__c` | reference → Asset | Direct handle from the household to its Membership asset. |
| `Out_Of_Territory__c` | boolean | Flags a member outside the club's service territory — **the real field for MD058CB's out-of-territory branch**, replacing any guessed equivalent. |
| `Region__c` | string, len 3 | Second key in the regional pricing lookup (paired with `Club_Code__c`). |
| `Role_Code__c` (picklist 00-06) / `Role_Type__c` (picklist AD/AS/DE/PR) | Member's position/category within the membership — Account-level counterparts to the OrderItem fields of the same name. |
| `Service_Branch__c` | reference → ServiceTerritory | Member's servicing branch. |

**Fields the business has explicitly said to remove — do not design around these:**
`Client_ID__c`, `FCC_Response__c`, `homePageAccount__c`, `Lodge_Club_Code__c` (a second club-code field — business confirmed not needed), `Related_Record_Flag__c`, `Updated_By__c`.

**Known automation gap:** `ACE_Membership_Cancellation` (would blank `OwnerId` when an Account has no related Assets) is **OBSOLETE — does not run**, despite firing on every Account update with no entry filter.

## Person Account (member-level fields, `__pc` suffix)

The member as an individual is a **Person Account** (`IsPersonAccount = true`); the household is modeled through `AccountContactRelation`. Standard `Person*` fields (`PersonEmail`, `PersonMobilePhone`, `PersonHomePhone`, `PersonBirthdate`, etc.) are the real contact-detail fields — **these replace every placeholder `Contact.Email`/`Contact.MobilePhone` reference in the original HLD/Apex scaffold**, since the actual model is Person Account, not a separate Contact used the way the scaffold assumed.

| Field | Type | Purpose |
|---|---|---|
| `Email_Status__pc` / `Mobile_Status__pc` / `Home_Phone_Status__pc` / `Other_Phone_Status__pc` | picklist (Valid/Invalid/Transactional Call Only/Declined) | **Deliverability state per channel** — this is the real signal for whether a member "has a usable phone/email," more precise than a null check. |
| `Member_Effective_Date__pc` | date | Correctly-typed member effective date (its sibling `Effective_Date__pc` is a duplicate stored as text — business confirmed the date field is the correct one). |
| `Preferred_Time_to_Call__pc` | picklist (Morning/Afternoon/Evening) | Contact-window preference. |
| `PersonHasOptedOutOfEmail` | boolean (standard) | Native email opt-out — use this over any custom consent field for email suppression. |

**Fields the business has explicitly said to remove:** `Membership__pc` ("unsure what it holds"), `Territory__pc` (overlaps `Account.Service_Branch__c`/`Out_Of_Territory__c`).

**Known duplicate-data issue (business confirmed, remediation in progress):** `MACS_Cust_Id__c` (Account) and `MACS_Cust_Id__pc` (Person) both carry the legacy MACS customer id in different contexts, which has produced duplicate accounts.

## Campaign_Code__c (real custom object — replaces the "invent a CMDT campaign whitelist" approach)

This object **already exists** and closely matches what `MD022EC`'s hard-coded campaign-code whitelist needs: `Club_Code__c` (picklist), `Campaign_Type__c` (97 values, reporting/attribution), `Channel__c` (mirrors `Order.Channel__c`), `Billing_Type__c` (Annual/Monthly/Both), `Pricing_Type__c` (New/Renewal/All), `Region__c`, `Effective_Date__c`/`Expiration_Date__c`, `Status__c` (Draft/Active/Rejected/Scheduled/Retired — all 25 current codes are Active), `AutoPay_Required__c`, `Multi_Year_Eligible__c` + `Next_Year_Campaign_Code__c` (self-lookup for step deals — currently null everywhere), `Code_Category__c` (Standard / MRU Save Offer / AutoPay Exception). `Campaign_Code_Name__c` is the human-facing code (e.g. `PO65%`, `PO$35`, `FREE ASSOC`) — **this, not the record Id, is what's stored in `OrderItem.Campaign_Code_Applied__c`**. Campaigns are cloned per club (e.g. `CC-00002`/`CC-00003`/`CC-00004` are the same `PO65%` offer for clubs 001/018/215).

**Critical gap: this object (and its child `Campaign_Action__c`) has NO automation whatsoever** — no flow, no Apex trigger, no validation rule. It's hand-maintained reference data. The discount/eligibility values it describes are **not currently enforced or applied to any order line by the platform**. `Campaign_Action__c` carries the actual discount mechanics (`Action_Type__c`: % Off/Flat $ Off/Set Price/Free Add-on/Tier Upgrade/Waive Fee/Gift, plus `Discount_Amount__c`/`Discount_Percent__c`/`Target_Price__c`), master-detail to `Campaign_Code__c` (cascade-deletes with it). Two fields on `Campaign_Action__c` are unresolved: `Product__c` vs `Target_Product__c` (which is "the product being discounted" vs. "the product being granted" is undocumented), and `Target_Category__c` (only placeholder picklist values, never configured).

**Design implication:** `RenewalEligibilityRules`'s campaign-code gate (the `MD022EC`-derived logic) should query real `Campaign_Code__c` records — `Club_Code__c` match, `Status__c = 'Active'`, today's date between `Effective_Date__c`/`Expiration_Date__c` — instead of a separately invented whitelist. Since the object has zero automation today, this migration would be the **first thing to actually enforce** these campaign rules at the platform level, not just replicate an existing enforcement mechanism.

## Known gap: no Billing/Payment object in this data dictionary

None of the 7 object sheets in this workbook cover Invoice, Payment, or a Billing Account/Treatment object — there is no `blng__Payment__c`, `blng__Invoice__c`, or standard `Order.Summary`/`InvoiceReceivable` equivalent visible here. This means:
- The "amount due" (`MD610BR` equivalent) and "payment in transit" (`FN435BT` equivalent) design pieces in `high-level-design.md` **remain unconfirmed** — this dictionary neither proves nor disproves Salesforce Billing is in use; it simply wasn't included in this audit's scope.
- Do not assume `blng__` objects exist in this org just because they weren't ruled out — treat billing/payment data source as a separate, still-open question requiring its own investigation before `MembershipRenewalNotificationBatch`'s `loadPaymentsInTransit`/`loadAmountDue` queries can be corrected.
