import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/permissions/access_control.dart';

// Onboarding / reference guide for the ERP. Static content (generated from a
// single source shared with the PDF). Visible to all orgs; no permission gate.
// Each item also carries a "where it lives" location (menu path) and, when the
// user is allowed to reach it, a one-click deep link to open the screen.

const String kOnboardingPdfUrl =
    'https://opstation-landing.web.app/opstation-onboarding-guide.pdf';

class _GuideItem {
  final String name;
  final String desc;
  const _GuideItem(this.name, this.desc);
}

class _GuideSection {
  final String title;
  final String intro;
  final List<_GuideItem> items;
  const _GuideSection(this.title, this.intro, this.items);
}

const List<_GuideSection> _kGuide = [
  _GuideSection(
    'Getting started',
    'The recommended setup order for a brand-new organization. Work top to bottom - each step builds on the one before it, so completing them in order saves rework. You only do this once; after that you work day to day in the modules below.',
    [
      _GuideItem('1. Branches', 'Create every location you operate - shops, warehouses, a factory. Almost everything in Opstation (stock, POS, most reports) is tracked per branch, and you pick which branch you are working in from the selector in the sidebar. Set these up first so the rest of your data has somewhere to live.'),
      _GuideItem('2. ERP Users & Permissions', 'Add your team under ERP > ERP Users and grant access one module at a time, so each person sees only what they need. You can also limit a user to specific branches. Do this early so colleagues can help with the remaining setup.'),
      _GuideItem('3. Chart of Accounts', 'Opstation ships with a standard set of accounts (numbered 1000-6999) covering assets, liabilities, equity, income and expenses. Review it and add any accounts specific to your business before you start posting transactions - every document will map to these accounts automatically.'),
      _GuideItem('4. Units of Measure & Classifications', 'Define how you count things (pieces, litre, box, carton) and how you group them into categories. Setting these up before you add products keeps your item list clean and your reports easy to filter.'),
      _GuideItem('5. Products', 'Add your items - each with its unit of measure, classification, cost/selling price and the branches that stock it. This is your master catalogue; sales, purchasing and manufacturing all draw from it. Mark labour or service lines (things you sell but do not hold in stock) as non-inventory items so they never affect stock or costing.'),
      _GuideItem('6. Opening balances', 'Tell Opstation where you stand today. Enter Opening Stock for on-hand inventory (quantity and value per branch) and an Opening Journal for cash, bank, and every customer and supplier balance. Getting this right means your first reports match your real position from day one.'),
      _GuideItem('7. Safeguards (recommended)', 'In Admin Settings, review the optional guards that keep your data clean from the start - for example blocking sales that would drive stock negative, or receipts booked at zero cost. Turning these on early prevents the kind of mess that is painful to untangle later.'),
      _GuideItem('8. Take the welcome tour', 'The first time each person signs in, a short guided tour introduces the parts of the system that matter for their role. You can replay it any time from your profile menu (top-right) > "Replay welcome tour".'),
      _GuideItem('9. Ask Station Master', 'Once an admin turns it on (Admin Settings > Assistant), a "Station Master" helper appears in the corner. Anyone can ask plain-language questions about their own data - stock of a product, a customer balance, today\'s sales, what is pending approval - and it answers only from the areas that person is allowed to see.'),
    ],
  ),
  _GuideSection(
    'Inventory',
    'Your items, how much of each you hold, what it is worth, and every movement that changes those numbers. Inventory sits at the centre of the system - purchasing feeds it, sales and production draw from it, and the ledgers value it.',
    [
      _GuideItem('Products', 'The master list of everything you buy, make or sell, each with its unit, classification, prices and the branches that carry it. Items flagged as non-inventory (service or labour) appear here too but are never stocked or costed. If product supervision is turned on (Admin Settings), each newly-created product is flagged for an admin to review, with a pendency counter on the menu - the product still works while it waits.'),
      _GuideItem('Branches', 'Your stocking locations. Every quantity and every valuation is held separately per branch, so you always know what is where.'),
      _GuideItem('Units of Measure', 'The units your items are counted and transacted in - pcs, kg, litre, box. Defined once, then reused across every product.'),
      _GuideItem('Product Classifications', 'Categories and groups you use to organise the catalogue and slice reports (by brand, type, department, and so on).'),
      _GuideItem('Opening Stock', 'The one-time entry of what you hold and what it cost when you go live. This is the starting point every later valuation builds on, so enter it carefully.'),
      _GuideItem('Stock Transfers', 'Move stock from one branch to another with a documented out-and-in trail, so both sides of the move are auditable.'),
      _GuideItem('Stock Adjustment', 'Correct on-hand quantities after a physical count, for wastage, or to fix an error. It posts the difference to your inventory adjustment account so the books stay in step with the shelf.'),
      _GuideItem('Stock Levels', 'The live on-hand quantity for every item in every branch - your real-time "what do we have" screen.'),
      _GuideItem('Low Stock Report', 'Every item at or below its reorder point, so you can replenish before anything runs out.'),
      _GuideItem('Stock Value Report', 'What your inventory is worth right now, by item and branch, using your chosen costing method.'),
      _GuideItem('Stock Balance Report', 'Opening quantity, movements in and out, and closing balance for a period - the quantity story of each item over time.'),
      _GuideItem('Stock Aging Report', 'How long stock has been sitting, bucketed by age, so you can spot slow-movers and dead stock before they tie up cash.'),
      _GuideItem('Inventory Ledger', 'The complete movement history of an item - every receipt, issue, transfer, production and adjustment - in date order. Your first stop when a number looks off.'),
      _GuideItem('Inventory Integrity', 'A health check that flags items whose physical stock, cost layers and ledger have drifted apart (for example a negative or zero-cost layer), tells you why in plain language, and offers a one-click fix. Run it periodically to keep valuations trustworthy.'),
    ],
  ),
  _GuideSection(
    'Purchasing',
    'The buy-side flow: Purchase Order to Goods Receipt Note to Purchase Invoice. Returns and supplier reports sit alongside it. Each document hands off to the next, so you always know what stage an order is at.',
    [
      _GuideItem('Purchase Dashboard', 'A single view of what is pending at each stage of buying and how long it has been waiting, so nothing slips.'),
      _GuideItem('Suppliers', 'Your vendor master - contact details, payment terms and opening balances.'),
      _GuideItem('Purchase Orders (PO)', 'The order you place with a supplier. It is the starting document of the purchase flow and commits nothing to stock or the books on its own.'),
      _GuideItem('GRN (Goods Receipt Note)', 'Records goods physically arriving against a PO. This is the step that actually increases your stock and creates the cost layer, so raise it when goods land.'),
      _GuideItem('Purchase Invoices (PI)', 'The supplier bill. It posts what you owe (the payable) and finalises the cost of the goods. Lock it to close the purchase cycle.'),
      _GuideItem('Purchase Return Notes', 'Send received goods back to a supplier; this reduces your stock.'),
      _GuideItem('Purchase Return Invoices', 'The financial credit against the supplier for goods you returned.'),
      _GuideItem('Purchase Price Variance', 'Where the price you were actually invoiced differs from the expected/order cost - a quick way to catch overcharges and pricing drift.'),
      _GuideItem('Supplier Ledger', 'The full account history for a supplier, from opening balance through every bill and payment.'),
      _GuideItem('Supplier Aging', 'Your outstanding payables sorted by how overdue they are, so you can plan what to pay and when.'),
    ],
  ),
  _GuideSection(
    'Sales',
    'The sell-side flow: Quotation to Sales Order to Delivery Order to Sales Invoice. Returns and customer reports sit alongside. As with purchasing, each document feeds the next so the pipeline is always visible.',
    [
      _GuideItem('Sales Dashboard', 'Pending sales documents by stage, with age, so no order stalls unnoticed.'),
      _GuideItem('Quotation', 'A price offer to a customer before they commit. Convert it to a Sales Order once accepted - no need to re-key anything.'),
      _GuideItem('Sales Orders (SO)', 'The customer order; the starting document of the sales flow.'),
      _GuideItem('Delivery Orders (DO)', 'Goods dispatched against an order. This is the step that actually reduces your stock and records the cost of goods sold.'),
      _GuideItem('Sales Invoices (SI)', 'The customer bill. It posts the receivable and your revenue. Numbers run as SI-YEAR-####. Lock it to finalise.'),
      _GuideItem('Sales Return Notes', 'Goods a customer sends back; this brings stock back in.'),
      _GuideItem('Sales Return Invoices', 'The financial credit issued to the customer for a return.'),
      _GuideItem('Sales Report', 'Sales performance with breakdowns you can drill into - by item, customer, branch or period.'),
      _GuideItem('Customer Ledger', 'The full account history for a customer, from opening balance through every invoice and receipt.'),
      _GuideItem('Customer Aging', 'Outstanding receivables sorted by how overdue they are, so you know who to chase.'),
    ],
  ),
  _GuideSection(
    'Point of Sale (POS)',
    'A fast counter-sales screen built for speed, isolated per branch, with its own catalogue and cash controls. Ideal for walk-in and retail-counter selling that still posts straight into your books.',
    [
      _GuideItem('Configuration', 'Set the POS behaviour and defaults for a branch before you start selling - receipt options, payment types and the like.'),
      _GuideItem('POS Catalog', 'The per-branch list of items available to sell at the counter, so cashiers only see what that shop stocks.'),
      _GuideItem('POS Terminal', 'The actual sell screen - quick billing, payments, change and printing, designed for keyboard-and-scanner speed.'),
      _GuideItem('Customer History', 'Past counter purchases for a walk-in or registered customer, handy for returns and loyalty.'),
      _GuideItem('Bills on Hold', 'Park an in-progress bill and pick it up again later without losing the cart - useful when a customer steps away.'),
      _GuideItem('Expense Management', 'Record cash paid out of the drawer during the day so end-of-day reconciliation ties out.'),
      _GuideItem('Promoters & Commission', 'Attribute a sale to a promoter and accrue their commission automatically; it posts to commission payable/expense with no manual calculation.'),
    ],
  ),
  _GuideSection(
    'Manufacturing',
    'Turn raw materials into finished goods, plan what you need, track the shop floor, and account for waste and rework - all valued into inventory automatically.',
    [
      _GuideItem('Production Floor', 'A live kanban of jobs by stage. Play and pause processing and see real-time status across the floor at a glance.'),
      _GuideItem('Product Assembly (BOM)', 'The recipe for a manufactured item - its components, plus labour and overhead. Everything downstream (costing, planning, production) reads from the BOM, so define it accurately.'),
      _GuideItem('Production Voucher', 'Consume the components and create the finished goods per the BOM. This is the document that moves value from raw materials into finished stock.'),
      _GuideItem('Production Material Planner', 'Works out what materials you need to buy or make. By default it reads real demand from your open Job Cards (queued and in-progress); you can switch it to a forecast when there are no active jobs. Lead days let it tell you when to order so material arrives in time.'),
      _GuideItem('Job Card', 'A work order on the floor, with remarks and a shop-floor print option that hides prices for the operators.'),
      _GuideItem('QC Checkpoints', 'The quality gates a job must pass before it can be completed - you define the checks once.'),
      _GuideItem('QC Station', 'Where operators actually record pass/fail against those checkpoints as jobs move through.'),
      _GuideItem('Production Inverse Voucher (Disassembly)', 'Break a finished item back down into its components. Pick an existing posted production voucher to reverse it at the exact costs it originally consumed, or work in free mode with your own component list. The finished goods go out and the components come back into stock, valued correctly.'),
      _GuideItem('Damage Stock Voucher', 'Write off damaged stock to the loss account so your on-hand and valuation stay honest.'),
      _GuideItem('Claim Processing Voucher', 'Process warranty or supplier claims against stock.'),
      _GuideItem('Goods without BOM', 'A watchlist of items (finished goods or raw materials) that have no recipe defined yet - fix these so their production and costing work correctly.'),
      _GuideItem('Production Waste Report', 'Material lost in production, broken down by job and item, so you can see where yield is leaking.'),
    ],
  ),
  _GuideSection(
    'Financials & Accounting',
    'A full double-entry accounting core. You rarely have to touch it directly - every sales, purchase, POS, production and return document posts to the General Ledger for you. These screens are where you adjust, pay, receive and read the results.',
    [
      _GuideItem('Chart of Accounts', 'The account tree - assets, liabilities, equity, income and expense. Control accounts (like receivables and payables) are protected from manual entry so their sub-ledgers always reconcile.'),
      _GuideItem('Journal Vouchers', 'General-purpose double-entry adjustments between any accounts, for the entries no standard document covers.'),
      _GuideItem('Opening Journal', 'The one-time entry that loads your opening balances for cash, bank, customers and suppliers when you go live.'),
      _GuideItem('Payment Vouchers (CPV)', 'Record money going out - paying a supplier or an expense.'),
      _GuideItem('Receipt Vouchers (CRV)', 'Record money coming in - a customer payment or other income.'),
      _GuideItem('PDC Voucher', 'Track post-dated cheques, in and out, until they mature and clear.'),
      _GuideItem('Cash Book Report', 'A running record of cash and bank movements, so you can reconcile against your statement.'),
      _GuideItem('Trial Balance', 'Every account with its balance on one screen - the quickest proof your books are in balance.'),
      _GuideItem('Account Activity', 'Drill into the individual transactions behind any account balance.'),
      _GuideItem('Profit & Loss', 'Your income statement for any period you choose.'),
      _GuideItem('Balance Sheet', 'Your financial position - assets, liabilities and equity - as of a given date.'),
    ],
  ),
  _GuideSection(
    'CRM',
    'Manage prospects and the relationship pipeline, beyond the plain transactional customer record.',
    [
      _GuideItem('Customers', 'Your CRM contact and account records - the relationship view of the people you sell to.'),
      _GuideItem('Pipeline', 'Deals on a kanban board moving through your sales stages, so you can see what is likely to close.'),
      _GuideItem('Follow-ups', 'Scheduled tasks and reminders against contacts; anything overdue surfaces as a badge so it does not get forgotten.'),
    ],
  ),
  _GuideSection(
    'Distribution & Field Sales (Opstation mobile app)',
    'The mobile companion for your field team - order booking, van/route delivery and doorstep collection. Everything captured on a phone, online or offline, syncs back into this panel in real time and posts to the same books.',
    [
      _GuideItem('Field Orders', 'Orders your salespeople book on the spot while visiting shops, which flow straight into the sales pipeline here.'),
      _GuideItem('Retailer Orders', 'Orders placed by retailers themselves (self-service), ready for you to fulfil.'),
      _GuideItem('Dispatch Orders', 'Group and release orders for dispatch, so the warehouse knows exactly what to load and send.'),
      _GuideItem('Deliveries', 'Run delivery runs and confirm each drop at the customer\'s door, with proof captured in the field.'),
      _GuideItem('Routes', 'The planned journey plans (which shops on which day) that structure your field team\'s week.'),
      _GuideItem('Live Map', 'See your field team and their visits on a live map, so you know coverage and where everyone is.'),
      _GuideItem('Collections', 'Cash and payments taken at the counter, recorded against the customer as they happen.'),
      _GuideItem('Reimbursements', 'Field expenses your team logs on the go, ready for you to review and settle.'),
    ],
  ),
  _GuideSection(
    'Market Intelligence',
    'Turn what your field team sees in the market into decisions - product placement, competitor presence and sales-target performance. This is populated by surveyors and salespeople syncing from the mobile app.',
    [
      _GuideItem('Intelligence Dashboard', 'Where your products are displayed (and where they are not), rolled up by market and route, from the latest audit per shop and SKU.'),
      _GuideItem('Placement Audit', 'The shop-by-shop, SKU-by-SKU survey of whether your products are on shelf and visible - the raw signal behind the dashboard.'),
      _GuideItem('Competitor Spotting', 'What competitor products are present in each shop and how they are positioned, so you can see where you are being out-placed.'),
      _GuideItem('Performance', 'Sales-target achievement for the month by salesperson and route, with drill-down to individual customers.'),
      _GuideItem('Competitor Categories & Brand Aliases', 'The reference lists that keep competitor data clean - grouping competitor products and mapping their many name variations to one canonical brand.'),
    ],
  ),
  _GuideSection(
    'Compliance',
    'Rule-based exception monitoring of your field operation. Instead of reading every report, you see only the customers and visits that break a rule and need attention.',
    [
      _GuideItem('No Collection in Last 3 Visits', 'Customers with three verified visits in a row that collected nothing - a sign of a stalling account.'),
      _GuideItem('No Visit in Last 3 Routes', 'Customers who were on the planned route three trips running but were never actually visited.'),
      _GuideItem('Skipped in Last 3 Routes', 'Customers marked skipped three trips in a row, so you can find out why.'),
      _GuideItem('Zero-amount verified visits', 'Visits confirmed as done but with no value recorded, worth a second look.'),
    ],
  ),
  _GuideSection(
    'HR',
    'Everyday people management for your team - who works for you, whether they showed up, and their time off.',
    [
      _GuideItem('Employee Directory', 'Your staff master records.'),
      _GuideItem('Attendance', 'Daily attendance tracking per employee.'),
      _GuideItem('Attendance Board', 'A live overview of who is in, out or on leave today.'),
      _GuideItem('Attendance Kiosk', 'A shared check-in screen staff can use to mark themselves present on arrival.'),
      _GuideItem('Leave', 'Leave requests and running balances.'),
    ],
  ),
  _GuideSection(
    'Assets & Facility',
    'Track what your business owns and keep your premises maintained.',
    [
      _GuideItem('Assets', 'A register of your fixed assets; items due for attention (service, renewal) surface as a badge.'),
      _GuideItem('Facility', 'Facility and maintenance tasks; anything due shows up as a badge so it is not missed.'),
    ],
  ),
  _GuideSection(
    'Team & Operations',
    'Manage the people in the field and the tools that support them - a per-person performance view, retailer logins, and the notifications you push to customers.',
    [
      _GuideItem('Team (360)', 'A single profile for each field team member - their route shops, trips and visits, collections and placement performance, all in one place.'),
      _GuideItem('Retailers', 'Create and manage login access for retailers so they can place their own orders.'),
      _GuideItem('Notifications', 'Compose and send targeted messages to customers or retailers (announcements, offers, reminders).'),
      _GuideItem('Files', 'Documents and files shared with your retailers.'),
      _GuideItem('Reports Center', 'A hub that gathers the standalone reports below in one place.'),
    ],
  ),
  _GuideSection(
    'Reports (quick index)',
    'Standalone reports gathered in the Reports Center. Remember that most modules above also carry their own built-in reports - aging, ledgers, dashboards, stock value and so on.',
    [
      _GuideItem('Margin Report', 'Profit margin sliced by sale, item or customer, so you can see what actually makes money.'),
      _GuideItem('Customer Balance Report', 'Outstanding balances across all customers in one list.'),
      _GuideItem('Supplier Balance Report', 'Outstanding balances across all suppliers in one list.'),
      _GuideItem('Skipped Receipts Report', 'Deliveries or dispatches that never got a receipt/collection booked against them - loose ends to close.'),
      _GuideItem('Module reports', 'For anything else, check the Inventory, Purchasing, Sales, POS, Manufacturing and Financials sections - each has its own dedicated reports.'),
    ],
  ),
  _GuideSection(
    'Controls & Administration',
    'The oversight layer that keeps every branch, every book and every user under control. This is where an owner or admin sets the rules of the system.',
    [
      _GuideItem('ERP Users & Permissions', 'Grant access one module at a time and scope each user to specific branches, so everyone sees exactly what they should.'),
      _GuideItem('Branch scoping', 'Limit the data a user can see by branch, using the branch selector in the sidebar.'),
      _GuideItem('Audit Trail', 'Every create, edit and void is logged with who did it and when - full accountability.'),
      _GuideItem('Approvals & locking', 'Finalise a document to lock it; only authorised roles can reopen or reverse it.'),
      _GuideItem('Data safeguards', 'Optional guards in Admin Settings that stop bad data at the source - for example blocking a sale that would push stock negative, or a receipt booked at zero cost. Recommended for keeping valuations clean.'),
      _GuideItem('Inventory Integrity & reconciliation', 'Tools to detect and repair drift between physical stock, cost layers and the general ledger, so your inventory and accounts stay in agreement over time.'),
      _GuideItem('Global search', 'Jump to any document from one search box, scoped to your permissions.'),
      _GuideItem('Station Master (assistant)', 'A plain-language helper, switched on per organisation in Admin Settings > Assistant. Users ask about their own data - stock, balances, sales, collection, pending approvals, where a voucher is - and it answers only from the areas each user can access, and only about system data. No general/AI exposure.'),
      _GuideItem('Dashboard privacy lock', 'Protect the main dashboard figures (especially collection and route numbers) behind a password set in Admin Settings. The master admin sees them by default; even admins must enter the password to reveal them. Set, change or remove the protection from Admin Settings.'),
      _GuideItem('Supervision flows', 'Optional review steps for new products, customers and GRNs. When on, each new record is flagged for an admin or master admin to "supervise", with a live pendency counter on the menu that clears as you review. Non-blocking - the record still works while it waits.'),
      _GuideItem('Guided welcome tour', 'A short, role-specific tour that plays on each person\'s first sign-in and can be replayed any time from the profile menu, so new team members find their way without training.'),
      _GuideItem('Admin Settings', 'Organisation-level settings, defaults and toggles - grouped by area (Sales, Purchase, Manufacturing, Inventory, Documents, Alerts, Assistant) so related switches sit together.'),
      _GuideItem('Automated daily backup', 'Every night a full export of your data is emailed to your designated address - a clean copy always kept off the system.'),
      _GuideItem('Menu layout', 'Switch between top-bar and sidebar navigation from the toggle next to search; your choice is remembered.'),
    ],
  ),
];

// ─── "Where it lives" metadata ──────────────────────────────────────────────
// A per-item location: the menu trail to reach it, and (when there's one screen
// to open) a deep link. Derived from the live navigation map, so the guide
// always tells you exactly where to click.
class _Loc {
  final String menu; // e.g. "Inventory" or "ERP ▸ Admin Settings"
  final String? route; // deep link, or null if there's no single screen to open
  const _Loc(this.menu, [this.route]);
}

const Map<String, IconData> _sectionIcon = {
  'Getting started': Icons.rocket_launch_outlined,
  'Inventory': Icons.inventory_2_outlined,
  'Purchasing': Icons.shopping_cart_outlined,
  'Sales': Icons.receipt_long_outlined,
  'Point of Sale (POS)': Icons.storefront_outlined,
  'Manufacturing': Icons.precision_manufacturing_outlined,
  'Financials & Accounting': Icons.account_balance_outlined,
  'CRM': Icons.contacts_outlined,
  'Distribution & Field Sales (Opstation mobile app)': Icons.local_shipping_outlined,
  'Market Intelligence': Icons.insights_outlined,
  'Compliance': Icons.rule_outlined,
  'HR': Icons.badge_outlined,
  'Assets & Facility': Icons.chair_outlined,
  'Team & Operations': Icons.groups_outlined,
  'Reports (quick index)': Icons.summarize_outlined,
  'Controls & Administration': Icons.admin_panel_settings_outlined,
};

// The default top-level menu that a section's items live under.
const Map<String, String> _sectionMenu = {
  'Getting started': '',
  'Inventory': 'Inventory',
  'Purchasing': 'Purchase',
  'Sales': 'Sales',
  'Point of Sale (POS)': 'POS',
  'Manufacturing': 'Manufacturing',
  'Financials & Accounting': 'Financials',
  'CRM': 'CRM',
  'Distribution & Field Sales (Opstation mobile app)': '',
  'Market Intelligence': 'Intelligence',
  'Compliance': 'Operations ▸ Compliance',
  'HR': 'HR',
  'Assets & Facility': 'Management',
  'Team & Operations': 'Operations',
  'Reports (quick index)': 'Reports',
  'Controls & Administration': 'ERP',
};

// Item name → route. Names are unique across the guide except "Products"
// (handled by the section-keyed override below).
const Map<String, String> _routeByName = {
  'Products': '/erp/products',
  'Branches': '/erp/branches',
  'Units of Measure': '/erp/uoms',
  'Product Classifications': '/erp/product-classifications',
  'Opening Stock': '/erp/opening-stock',
  'Stock Transfers': '/erp/stock-transfers',
  'Stock Adjustment': '/erp/stock-adjustment',
  'Stock Levels': '/erp/stock',
  'Low Stock Report': '/erp/low-stock-report',
  'Stock Value Report': '/erp/stock-value-report',
  'Stock Balance Report': '/erp/stock-balance-report',
  'Stock Aging Report': '/erp/stock-aging-report',
  'Inventory Ledger': '/erp/inventory-ledger',
  'Inventory Integrity': '/erp/inventory-integrity',
  'Purchase Dashboard': '/erp/purchase-dashboard',
  'Suppliers': '/erp/suppliers',
  'Purchase Orders (PO)': '/erp/purchase',
  'GRN (Goods Receipt Note)': '/erp/grn',
  'Purchase Invoices (PI)': '/erp/purchase-invoices',
  'Purchase Return Notes': '/erp/purchase-returns',
  'Purchase Return Invoices': '/erp/purchase-return-vouchers',
  'Purchase Price Variance': '/erp/purchase-variance',
  'Supplier Ledger': '/erp/supplier-ledger',
  'Supplier Aging': '/erp/supplier-aging',
  'Sales Dashboard': '/erp/sales-dashboard',
  'Quotation': '/erp/quotation',
  'Sales Orders (SO)': '/erp/sales',
  'Delivery Orders (DO)': '/erp/delivery-orders',
  'Sales Invoices (SI)': '/erp/sales-invoices',
  'Sales Return Notes': '/erp/sales-returns',
  'Sales Return Invoices': '/erp/sales-return-invoices',
  'Sales Report': '/erp/sales-report',
  'Customer Ledger': '/erp/customer-ledger',
  'Customer Aging': '/erp/customer-aging',
  'Configuration': '/erp/pos-config',
  'POS Catalog': '/erp/pos-catalog',
  'POS Terminal': '/erp/pos',
  'Customer History': '/erp/pos-customer-history',
  'Bills on Hold': '/erp/pos-held-bills',
  'Expense Management': '/erp/pos-expense-management',
  'Promoters & Commission': '/erp/promoters',
  'Production Floor': '/manufacturing/production-floor',
  'Product Assembly (BOM)': '/manufacturing/product-assembly',
  'Production Voucher': '/manufacturing/production-voucher',
  'Production Material Planner': '/manufacturing/production-plan',
  'Job Card': '/manufacturing/job-card',
  'QC Checkpoints': '/manufacturing/qc-checkpoints',
  'QC Station': '/manufacturing/qc-station',
  'Production Inverse Voucher (Disassembly)': '/manufacturing/production-inverse-voucher',
  'Damage Stock Voucher': '/manufacturing/damage-stock-voucher',
  'Claim Processing Voucher': '/manufacturing/claim-processing-voucher',
  'Goods without BOM': '/erp/fg-without-bom',
  'Production Waste Report': '/manufacturing/production-waste-report',
  'Chart of Accounts': '/erp/chart-of-accounts',
  'Journal Vouchers': '/financials/journal-vouchers',
  'Opening Journal': '/financials/opening-journal',
  'Payment Vouchers (CPV)': '/erp/payment-vouchers',
  'Receipt Vouchers (CRV)': '/erp/receipt-vouchers',
  'PDC Voucher': '/erp/pdc-voucher',
  'Cash Book Report': '/financials/cash-book',
  'Trial Balance': '/financials/trial-balance',
  'Account Activity': '/financials/account-activity',
  'Profit & Loss': '/financials/profit-loss',
  'Balance Sheet': '/financials/balance-sheet',
  'Customers': '/crm/customers',
  'Pipeline': '/crm/pipeline',
  'Follow-ups': '/crm/follow-ups',
  'Field Orders': '/erp/field-orders',
  'Retailer Orders': '/erp/retailer-orders',
  'Dispatch Orders': '/dispatch-orders',
  'Deliveries': '/deliveries',
  'Routes': '/routes',
  'Live Map': '/live-map',
  'Intelligence Dashboard': '/intelligence/dashboard',
  'Placement Audit': '/intelligence/placement',
  'Competitor Spotting': '/intelligence/competitors',
  'Performance': '/intelligence/performance',
  'Competitor Categories & Brand Aliases': '/competitor-categories',
  'No Collection in Last 3 Visits': '/compliance',
  'No Visit in Last 3 Routes': '/compliance',
  'Skipped in Last 3 Routes': '/compliance',
  'Zero-amount verified visits': '/compliance',
  'Employee Directory': '/hr/employees',
  'Attendance': '/hr/attendance',
  'Attendance Board': '/hr/attendance-board',
  'Attendance Kiosk': '/hr/attendance-kiosk',
  'Leave': '/hr/leave',
  'Assets': '/assets',
  'Facility': '/facility',
  'Team (360)': '/team',
  'Retailers': '/operations/retailers',
  'Notifications': '/operations/notifications',
  'Files': '/operations/files',
  'Reports Center': '/reports/center',
  'Margin Report': '/reports/margin',
  'Customer Balance Report': '/reports/customer-balance',
  'Supplier Balance Report': '/reports/supplier-balance',
  'Skipped Receipts Report': '/reports/skipped-receipts',
  'ERP Users & Permissions': '/erp/users',
  'Branch scoping': '/erp/branches',
  'Audit Trail': '/erp/audit-log',
  'Data safeguards': '/erp/admin-settings',
  'Inventory Integrity & reconciliation': '/erp/inventory-integrity',
  'Station Master (assistant)': '/erp/admin-settings',
  'Dashboard privacy lock': '/erp/admin-settings',
  'Supervision flows': '/erp/admin-settings',
  'Automated daily backup': '/erp/admin-settings',
  'Admin Settings': '/erp/admin-settings',
  '1. Branches': '/erp/branches',
  '2. ERP Users & Permissions': '/erp/users',
  '3. Chart of Accounts': '/erp/chart-of-accounts',
  '4. Units of Measure & Classifications': '/erp/uoms',
  '5. Products': '/erp/products',
  '6. Opening balances': '/financials/opening-journal',
  '7. Safeguards (recommended)': '/erp/admin-settings',
  '9. Ask Station Master': '/erp/admin-settings',
};

// Item name → menu override (when it differs from the section's default menu).
const Map<String, String> _menuByName = {
  'Branches': 'ERP',
  'Field Orders': 'Sales',
  'Retailer Orders': 'Sales',
  'Dispatch Orders': 'Dispatch',
  'Deliveries': 'Operations',
  'Routes': 'Operations',
  'Live Map': 'Operations',
  'Collections': 'Opstation mobile app',
  'Reimbursements': 'Opstation mobile app',
  'Reports Center': 'Reports',
  'Competitor Categories & Brand Aliases': 'Intelligence ▸ Setup',
  'ERP Users & Permissions': 'ERP ▸ Administration',
  'Audit Trail': 'ERP ▸ Administration',
  'Data safeguards': 'ERP ▸ Admin Settings',
  'Inventory Integrity & reconciliation': 'Inventory',
  'Global search': 'Top bar',
  'Station Master (assistant)': 'ERP ▸ Admin Settings',
  'Dashboard privacy lock': 'ERP ▸ Admin Settings',
  'Supervision flows': 'ERP ▸ Admin Settings',
  'Guided welcome tour': 'Profile menu',
  'Approvals & locking': 'Across documents',
  'Automated daily backup': 'ERP ▸ Admin Settings',
  'Menu layout': 'Top bar',
  'Admin Settings': 'ERP ▸ Administration',
  'Branch scoping': 'ERP',
  '1. Branches': 'ERP',
  '2. ERP Users & Permissions': 'ERP ▸ Administration',
  '3. Chart of Accounts': 'Financials',
  '4. Units of Measure & Classifications': 'Inventory',
  '5. Products': 'Inventory',
  '6. Opening balances': 'Financials',
  '7. Safeguards (recommended)': 'ERP ▸ Admin Settings',
  '8. Take the welcome tour': 'Profile menu',
  '9. Ask Station Master': 'ERP ▸ Admin Settings',
};

// Section|Name overrides for the few duplicate item names.
const Map<String, String> _routeBySectionName = {
  'Market Intelligence|Products': '/products',
};
const Map<String, String> _menuBySectionName = {
  'Market Intelligence|Products': 'Intelligence ▸ Setup',
};

_Loc _locFor(String sectionTitle, String itemName) {
  final key = '$sectionTitle|$itemName';
  final route = _routeBySectionName[key] ?? _routeByName[itemName];
  final menu = _menuBySectionName[key] ??
      _menuByName[itemName] ??
      (_sectionMenu[sectionTitle] ?? '');
  return _Loc(menu, route);
}

// A soft accent colour per section, so the long guide reads as distinct blocks
// rather than one grey wall.
const List<Color> _accents = [
  Color(0xFF2F6FED), // blue
  Color(0xFF0EA5A4), // teal
  Color(0xFF7C3AED), // violet
  Color(0xFFEA580C), // orange
  Color(0xFF0891B2), // cyan
  Color(0xFFDB2777), // pink
  Color(0xFF059669), // green
  Color(0xFF4F46E5), // indigo
];

class ErpOnboardingScreen extends ConsumerStatefulWidget {
  const ErpOnboardingScreen({super.key});

  @override
  ConsumerState<ErpOnboardingScreen> createState() =>
      _ErpOnboardingScreenState();
}

class _ErpOnboardingScreenState extends ConsumerState<ErpOnboardingScreen> {
  String _q = '';
  final Map<String, GlobalKey> _sectionKeys = {
    for (final s in _kGuide) s.title: GlobalKey(),
  };

  List<_GuideSection> get _filtered {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _kGuide;
    final out = <_GuideSection>[];
    for (final s in _kGuide) {
      if (s.title.toLowerCase().contains(q) || s.intro.toLowerCase().contains(q)) {
        out.add(s);
        continue;
      }
      final items = s.items.where((i) {
        final loc = _locFor(s.title, i.name);
        return i.name.toLowerCase().contains(q) ||
            i.desc.toLowerCase().contains(q) ||
            loc.menu.toLowerCase().contains(q);
      }).toList();
      if (items.isNotEmpty) out.add(_GuideSection(s.title, s.intro, items));
    }
    return out;
  }

  bool _canOpen(String? route) {
    if (route == null) return false;
    final access = ref.read(accessSyncProvider);
    if (access == null) return true; // still loading — let the router decide
    return access.canAccessRoute(route);
  }

  void _jumpTo(String title) {
    if (_q.trim().isNotEmpty) setState(() => _q = '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKeys[title]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
            alignment: 0.02);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sections = _filtered;
    return ColoredBox(
      color: const Color(0xFFF6F8FC),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _hero(context)),
          SliverToBoxAdapter(child: _quickJump()),
          if (sections.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(
                    child: Text('No matches.',
                        style: TextStyle(color: Color(0xFF5B6473)))),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: Column(
                      children: [
                        for (var i = 0; i < sections.length; i++)
                          _sectionCard(sections[i], i),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Hero header ──
  Widget _hero(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF14285F), Color(0xFF1D46A0), Color(0xFF2F6FED)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 26),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.35)),
                    ),
                    alignment: Alignment.center,
                    child: const Text('O',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Onboarding Guide',
                            style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -0.4)),
                        const SizedBox(height: 4),
                        Text(
                          'The planet\'s best ERP for the trading & distribution industry.',
                          style: TextStyle(
                              fontSize: 13.5,
                              color: Colors.white.withOpacity(0.85)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () =>
                        html.window.open(kOnboardingPdfUrl, '_blank'),
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('Download PDF'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.55)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // Search
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  style: const TextStyle(color: Color(0xFF0F1729)),
                  decoration: InputDecoration(
                    hintText: 'Search a screen, report or voucher…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 18, runSpacing: 8, children: [
                _heroStat('16', 'modules'),
                _heroStat('124', 'features & reports'),
                _heroStat('Tip', 'each item shows where to find it'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroStat(String big, String small) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(big,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 14)),
      const SizedBox(width: 6),
      Text(small,
          style: TextStyle(
              color: Colors.white.withOpacity(0.8), fontSize: 12)),
    ]);
  }

  // ── Quick-jump chips ──
  Widget _quickJump() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _kGuide.length; i++)
                _jumpChip(_kGuide[i].title, i),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jumpChip(String title, int i) {
    final accent = _accents[i % _accents.length];
    final icon = _sectionIcon[title] ?? Icons.folder_outlined;
    // Compact label for the long section names.
    final label = title.contains('(') ? title.split('(').first.trim() : title;
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: () => _jumpTo(title),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: accent.withOpacity(0.28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent.withOpacity(0.95))),
        ]),
      ),
    );
  }

  // ── Section card ──
  Widget _sectionCard(_GuideSection s, int index) {
    final accent = _accents[index % _accents.length];
    final icon = _sectionIcon[s.title] ?? Icons.folder_outlined;
    return Container(
      key: _sectionKeys[s.title],
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE6EAF2)),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF0F1729).withOpacity(0.03),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              gradient: LinearGradient(
                colors: [accent.withOpacity(0.10), accent.withOpacity(0.02)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(s.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                                color: Color(0xFF0F1729))),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${s.items.length}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: accent)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(s.intro,
                        style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Color(0xFF5B6473))),
                  ],
                ),
              ),
            ]),
          ),
          // items grid
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            child: LayoutBuilder(builder: (ctx, cons) {
              final cols = cons.maxWidth > 720 ? 2 : 1;
              final w = (cons.maxWidth - (cols - 1) * 12) / cols;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final it in s.items)
                    SizedBox(
                      width: w,
                      child: _FeatureCard(
                        name: it.name,
                        desc: it.desc,
                        loc: _locFor(s.title, it.name),
                        accent: accent,
                        canOpen: _canOpen(_locFor(s.title, it.name).route),
                        onOpen: () {
                          final r = _locFor(s.title, it.name).route;
                          if (r != null) context.go(r);
                        },
                      ),
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

// A single feature/voucher/report card: name, its location breadcrumb, and the
// description. Clickable (with a hover lift) when the user can reach the screen.
class _FeatureCard extends StatefulWidget {
  final String name;
  final String desc;
  final _Loc loc;
  final Color accent;
  final bool canOpen;
  final VoidCallback onOpen;
  const _FeatureCard({
    required this.name,
    required this.desc,
    required this.loc,
    required this.accent,
    required this.canOpen,
    required this.onOpen,
  });

  @override
  State<_FeatureCard> createState() => _FeatureCardState();
}

class _FeatureCardState extends State<_FeatureCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final clickable = widget.canOpen;
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) { if (clickable) setState(() => _hover = true); },
      onExit: (_) { if (clickable) setState(() => _hover = false); },
      child: GestureDetector(
        onTap: clickable ? widget.onOpen : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
          decoration: BoxDecoration(
            color: _hover ? widget.accent.withOpacity(0.04) : const Color(0xFFFBFCFE),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _hover
                    ? widget.accent.withOpacity(0.45)
                    : const Color(0xFFE6EAF2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(widget.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: Color(0xFF0F1729))),
                ),
                if (clickable)
                  Icon(Icons.north_east,
                      size: 14,
                      color: _hover
                          ? widget.accent
                          : const Color(0xFFB0B8C6)),
              ]),
              const SizedBox(height: 7),
              _locationPill(),
              const SizedBox(height: 8),
              Text(widget.desc,
                  style: const TextStyle(
                      fontSize: 12.3, height: 1.4, color: Color(0xFF4B5563))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _locationPill() {
    final menu = widget.loc.menu;
    final label = menu.isEmpty ? widget.name : '$menu  ▸  ${widget.name}';
    final color = widget.canOpen ? widget.accent : const Color(0xFF7A8394);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.09),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.place_outlined, size: 12, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ),
      ]),
    );
  }
}
