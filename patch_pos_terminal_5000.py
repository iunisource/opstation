#!/usr/bin/env python3
# Paginates the POS SALE TERMINAL's product + stock loads so they no longer
# truncate at the project's PostgREST max-rows cap (5000). There was never a
# literal .limit(5000) here — a bare .select() silently stops at the server cap.
# Run from the repo root: python3 patch_pos_terminal_5000.py
import os

F = "opstation_web/lib/features/erp/presentation/erp_pos_screen.dart"
s = open(F, encoding="utf-8").read()
before = s.count("\n") + 1

def rep(old, new, label):
    global s
    c = s.count(old)
    assert c == 1, f"ABORT {label}: expected 1 match, found {c}"
    s = s.replace(old, new)
    print(f"OK  {label}")

# 1) Insert the paginating helper immediately before _loadData().
HELPER = """  // Pages past PostgREST's server-side max-rows cap (this project = 5000).
  // A bare .select() silently truncates at that cap with NO error, so the POS
  // terminal was loading at most 5000 products / stock rows. Page in 1000-row
  // batches (1000 is <= any max-rows value, so a short page reliably means
  // "end reached"). Returns a Future<List> so it drops into Future.wait.
  Future<List<Map<String, dynamic>>> _fetchAllPaged(
      dynamic Function(int from, int to) buildPage) async {
    const pageSz = 1000;
    final out = <Map<String, dynamic>>[];
    for (var from = 0; ; from += pageSz) {
      final rows = List<Map<String, dynamic>>.from(
          await buildPage(from, from + pageSz - 1) as List);
      out.addAll(rows);
      if (rows.length < pageSz) break;
    }
    return out;
  }

  Future<void> _loadData() async {"""
rep("  Future<void> _loadData() async {", HELPER, "insert _fetchAllPaged helper")

# 2) pos_catalog (results[1]) -> paginated. Adds .order('id') tiebreaker for
#    stable paging when product names repeat.
rep(
    "        client.from('pos_catalog').select('id, name, sku, price, is_active, product_id, uom_id').eq('org_id', orgId).eq('branch_id', branchId).eq('is_active', true).order('name'),",
    "        _fetchAllPaged((from, to) => client.from('pos_catalog').select('id, name, sku, price, is_active, product_id, uom_id').eq('org_id', orgId).eq('branch_id', branchId).eq('is_active', true).order('name').order('id').range(from, to)),",
    "paginate pos_catalog (results[1])",
)

# 3) inventory_stock (results[4]) -> paginated.
rep(
    "        client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId),",
    "        _fetchAllPaged((from, to) => client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId).order('product_id').range(from, to)),",
    "paginate inventory_stock (results[4])",
)

open(F, "w", encoding="utf-8").write(s)
after = s.count("\n") + 1
print(f"\nwritten: {F}")
print(f"lines: {before} -> {after}  (expected +17)")
