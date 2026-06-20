import 'dart:html' as html;
import 'package:flutter/material.dart';

// Onboarding / reference guide for the ERP. Static content (generated from a
// single source shared with the PDF). Visible to all orgs; no permission gate.

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
    'Recommended setup order for a new organization. Work top to bottom; each step builds on the previous one.',
    [
      _GuideItem('1. Branches', 'Create your locations (shops, warehouses, factory). Stock, POS and reports are scoped per branch; pick the active branch from the sidebar selector.'),
      _GuideItem('2. ERP Users & Permissions', 'Add your team under ERP > ERP Users and grant access module by module. Each user can be scoped to specific branches.'),
      _GuideItem('3. Chart of Accounts', 'Review the pre-loaded accounts (1000-6999). Add any accounts specific to your business before posting.'),
      _GuideItem('4. Units of Measure & Classifications', 'Define how you count items (pcs, litre, box) and how you group them, before adding products.'),
      _GuideItem('5. Products', 'Add your items with their UoM, classification and branches.'),
      _GuideItem('6. Opening balances', 'Enter Opening Stock for inventory and an Opening Journal for cash, bank, customer and supplier balances to start from your real position.'),
    ],
  ),
  _GuideSection(
    'Inventory',
    'Items, stock levels and the movements that change them.',
    [
      _GuideItem('Products', 'Master list of items with units, classifications and per-branch availability.'),
      _GuideItem('Branches', 'Your stocking locations; every quantity and valuation is tracked per branch.'),
      _GuideItem('Units of Measure', 'The units items are counted and transacted in.'),
      _GuideItem('Product Classifications', 'Categories and groups used to organize and filter products and reports.'),
      _GuideItem('Opening Stock', 'One-time entry of on-hand quantities and values when you go live.'),
      _GuideItem('Stock Transfers', 'Move stock from one branch to another with a documented in/out trail.'),
      _GuideItem('Stock Adjustment', 'Correct on-hand quantities for counts, wastage or errors; posts to the inventory adjustment account.'),
      _GuideItem('Stock Levels', 'Live on-hand quantity per item per branch.'),
      _GuideItem('Low Stock Report', 'Items at or below their reorder point, so nothing runs out unnoticed.'),
      _GuideItem('Stock Value Report', 'Current inventory valuation by item and branch.'),
      _GuideItem('Inventory Ledger', 'Every movement for an item - receipts, issues, transfers and adjustments - in date order.'),
    ],
  ),
  _GuideSection(
    'Purchasing',
    'The buy-side flow runs PO -> GRN -> Purchase Invoice, with returns and supplier reports alongside.',
    [
      _GuideItem('Purchase Dashboard', 'At-a-glance view of what is pending at each purchasing stage and how old it is.'),
      _GuideItem('Suppliers', 'Your vendor master with contact, terms and opening balances.'),
      _GuideItem('Purchase Orders (PO)', 'Order goods from a supplier; the starting document of the purchase flow.'),
      _GuideItem('GRN (Goods Receipt Note)', 'Record goods physically received against a PO; this is what increases stock.'),
      _GuideItem('Purchase Invoices (PI)', 'The supplier bill; posts the payable and finalizes cost. Lock it to close the cycle.'),
      _GuideItem('Purchase Return Notes', 'Send received goods back to a supplier; reduces stock.'),
      _GuideItem('Purchase Return Invoices', 'The financial credit for returned goods against the supplier.'),
      _GuideItem('Supplier Ledger', 'Full account history per supplier, including opening balance and reference type.'),
      _GuideItem('Supplier Aging', 'Outstanding payables bucketed by how overdue they are.'),
    ],
  ),
  _GuideSection(
    'Sales',
    'The sell-side flow runs SO -> DO -> Sales Invoice, with returns and customer reports alongside.',
    [
      _GuideItem('Sales Dashboard', 'Pending sales documents by stage with age, so nothing stalls.'),
      _GuideItem('Sales Orders (SO)', 'Customer order; the starting document of the sales flow.'),
      _GuideItem('Delivery Orders (DO)', 'Goods dispatched against an order; this is what reduces stock.'),
      _GuideItem('Sales Invoices (SI)', 'The customer bill; posts the receivable and revenue. Voucher numbers run as SI-YEAR-####. Lock to finalize.'),
      _GuideItem('Sales Return Notes', 'Goods returned by a customer; brings stock back in.'),
      _GuideItem('Sales Return Invoices', 'The financial credit issued to the customer for returns.'),
      _GuideItem('Sales Report', 'Sales performance with breakdowns you can drill into.'),
      _GuideItem('Customer Ledger', 'Full account history per customer, including opening balance.'),
      _GuideItem('Customer Aging', 'Outstanding receivables bucketed by how overdue they are.'),
    ],
  ),
  _GuideSection(
    'Point of Sale (POS)',
    'A fast counter-sales screen, isolated per branch, with its own catalog and cash controls.',
    [
      _GuideItem('Configuration', 'Set up POS behaviour and defaults for the branch.'),
      _GuideItem('POS Catalog', 'The per-branch list of items available to sell at the counter.'),
      _GuideItem('POS terminal', 'The sell screen for quick billing, payments and printing.'),
      _GuideItem('Customer History', 'Past POS purchases for a walk-in or registered customer.'),
      _GuideItem('Bills on Hold', 'Park an in-progress bill and resume it later without losing the cart.'),
      _GuideItem('Expense Management', 'Record counter cash expenses so the drawer reconciles.'),
      _GuideItem('Promoters & Commission', 'Attribute sales to promoters and accrue their commission automatically (posts to commission payable / expense).'),
    ],
  ),
  _GuideSection(
    'Manufacturing',
    'Turn raw materials into finished goods, track the shop floor, and account for waste and rework.',
    [
      _GuideItem('Production Floor', 'Live kanban of jobs by stage; play/pause processing with real-time status.'),
      _GuideItem('Product Assembly (BOM)', 'Define the recipe - components, labor and overhead - for a manufactured item.'),
      _GuideItem('Production Voucher', 'Consume components and produce finished goods per the BOM.'),
      _GuideItem('Job Card', 'A work order on the floor, with remarks and a shop-floor (no-price) print option.'),
      _GuideItem('QC Checkpoints', 'Quality gates a job must pass through before completion.'),
      _GuideItem('Production Inverse Voucher', 'Reverse a production run - break a finished item back into components.'),
      _GuideItem('Damage Stock Voucher', 'Write off damaged stock to the loss account.'),
      _GuideItem('Claim Processing Voucher', 'Process warranty or supplier claims on stock.'),
      _GuideItem('Production Waste Report', 'Material lost in production, by job and item.'),
    ],
  ),
  _GuideSection(
    'Financials & Accounting',
    'A full double-entry core. Every sales, purchase, POS and return document posts to the General Ledger automatically.',
    [
      _GuideItem('Chart of Accounts', 'The account tree (assets, liabilities, equity, income, expense). Control accounts (AR/AP) block manual entries.'),
      _GuideItem('Journal Vouchers', 'General-purpose double-entry adjustments between accounts.'),
      _GuideItem('Opening Journal', 'One-time entry to load opening balances for cash, bank, customers and suppliers.'),
      _GuideItem('Payment Vouchers (CPV)', 'Record money paid out (to suppliers or for expenses).'),
      _GuideItem('Receipt Vouchers (CRV)', 'Record money received (from customers or other income).'),
      _GuideItem('PDC Voucher', 'Track post-dated cheques in and out until they mature.'),
      _GuideItem('Trial Balance', 'Every account with its balance; the books in one screen.'),
      _GuideItem('Account Activity', 'Drill into the transactions behind any account.'),
      _GuideItem('Profit & Loss', 'Income statement for a chosen period.'),
      _GuideItem('Balance Sheet', 'Financial position - assets, liabilities and equity - as of a date.'),
    ],
  ),
  _GuideSection(
    'CRM',
    'Manage prospects and the relationship pipeline beyond the transactional customer record.',
    [
      _GuideItem('Customers', 'CRM contact and account records.'),
      _GuideItem('Pipeline', 'Deals on a kanban board moving through your sales stages.'),
      _GuideItem('Follow-ups', 'Scheduled tasks and reminders; overdue items surface as a badge.'),
    ],
  ),
  _GuideSection(
    'HR',
    'Basic people management for your team.',
    [
      _GuideItem('Employee Directory', 'Your staff master records.'),
      _GuideItem('Attendance', 'Daily attendance tracking.'),
      _GuideItem('Leave', 'Leave requests and balances.'),
    ],
  ),
  _GuideSection(
    'Assets & Facility',
    'Track what you own and keep your premises in order.',
    [
      _GuideItem('Assets', 'Fixed-asset register; items due for attention surface as a badge.'),
      _GuideItem('Facility', 'Facility and maintenance tasks; due items surface as a badge.'),
    ],
  ),
  _GuideSection(
    'Field Operations (Opstation App)',
    'The mobile companion for the field team. Everything captured syncs back to this panel in real time.',
    [
      _GuideItem('Order capture', 'Book customer orders on the spot, online or offline.'),
      _GuideItem('Deliveries', 'Run delivery routes and confirm drops at the doorstep.'),
      _GuideItem('Shop visits', 'Mark visits to shops and outlets in the field.'),
      _GuideItem('Collections', 'Record cash and payment collections at the counter.'),
      _GuideItem('Reimbursements', 'Log field expenses and reimbursements as they happen.'),
    ],
  ),
  _GuideSection(
    'Reports (quick index)',
    'Standalone reports. Most modules above also carry their own reports (aging, ledgers, dashboards, stock value, etc.).',
    [
      _GuideItem('Margin Report', 'Profit margin by sale, item or customer.'),
      _GuideItem('Customer Balance Report', 'Outstanding balances across customers.'),
      _GuideItem('Module reports', 'See Inventory, Purchasing, Sales, POS and Financials sections for their dedicated reports.'),
    ],
  ),
  _GuideSection(
    'Controls & Administration',
    'The oversight layer that keeps every branch and every book under control.',
    [
      _GuideItem('ERP Users & Permissions', 'Grant access module by module; scope each user to specific branches.'),
      _GuideItem('Branch scoping', 'Limit what data a user sees by branch via the sidebar branch selector.'),
      _GuideItem('Audit Trail', 'Every create, edit and void is logged with who did it and when.'),
      _GuideItem('Approvals & locking', 'Finalize a document to lock it; only authorized roles can reopen or reverse.'),
      _GuideItem('Global search', 'Jump to any document from one search box, scoped to your permissions.'),
      _GuideItem('Admin Settings', 'Organization-level settings and toggles.'),
      _GuideItem('Automated daily backup', 'Every night a full data export is emailed to your designated address - a clean copy always off the system.'),
      _GuideItem('Menu layout', 'Switch between top-bar and sidebar navigation from the toggle next to search; your choice is remembered.'),
    ],
  ),
];

class ErpOnboardingScreen extends StatefulWidget {
  const ErpOnboardingScreen({super.key});

  @override
  State<ErpOnboardingScreen> createState() => _ErpOnboardingScreenState();
}

class _ErpOnboardingScreenState extends State<ErpOnboardingScreen> {
  String _q = '';

  List<_GuideSection> get _filtered {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _kGuide;
    final out = <_GuideSection>[];
    for (final s in _kGuide) {
      if (s.title.toLowerCase().contains(q) || s.intro.toLowerCase().contains(q)) {
        out.add(s);
        continue;
      }
      final items = s.items
          .where((i) =>
              i.name.toLowerCase().contains(q) || i.desc.toLowerCase().contains(q))
          .toList();
      if (items.isNotEmpty) out.add(_GuideSection(s.title, s.intro, items));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final searching = _q.trim().isNotEmpty;
    final sections = _filtered;

    return ColoredBox(
      color: const Color(0xFFF6F8FC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.menu_book_outlined, color: primary, size: 26),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Onboarding Guide',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F1729))),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => html.window.open(kOnboardingPdfUrl, '_blank'),
                          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                          label: const Text('Download PDF'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: BorderSide(color: primary.withOpacity(0.5)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'A reference to every module, voucher and report in Opstation ERP.',
                      style: TextStyle(fontSize: 13.5, color: Color(0xFF5B6473)),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      onChanged: (v) => setState(() => _q = v),
                      decoration: InputDecoration(
                        hintText: 'Search features, vouchers, reports...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF1F4FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE6EAF2)),
          // ── Sections ──
          Expanded(
            child: sections.isEmpty
                ? const Center(
                    child: Text('No matches.',
                        style: TextStyle(color: Color(0xFF5B6473))))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 940),
                          child: Column(
                            children: [
                              for (var i = 0; i < sections.length; i++)
                                _sectionCard(context, sections[i], primary,
                                    expanded: searching || i == 0),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard(BuildContext context, _GuideSection s, Color primary,
      {required bool expanded}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE6EAF2)),
      ),
      color: Colors.white,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('${s.title}_$expanded'),
          initiallyExpanded: expanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          title: Text(s.title,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15.5, color: primary)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.intro,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFF5B6473))),
          ),
          children: [
            for (final it in s.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 6, right: 12),
                      decoration:
                          BoxDecoration(color: primary, shape: BoxShape.circle),
                    ),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF39414F),
                              height: 1.38),
                          children: [
                            TextSpan(
                                text: '${it.name}  ',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F1729))),
                            TextSpan(text: it.desc),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
