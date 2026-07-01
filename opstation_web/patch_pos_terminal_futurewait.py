#!/usr/bin/env python3
# Fixes the Future.wait type-inference error introduced by the pagination patch.
# The mixed list (query builders + Future<List<Map>> from _fetchAllPaged) makes
# Dart infer List<Object>; the explicit <dynamic> restores Iterable<Future>.
# Run from the repo root: python3 patch_pos_terminal_futurewait.py
F = "opstation_web/lib/features/erp/presentation/erp_pos_screen.dart"
s = open(F, encoding="utf-8").read()

old = "      final results = await Future.wait(["
new = "      final results = await Future.wait<dynamic>(["
c = s.count(old)
assert c == 1, f"ABORT: expected 1 match, found {c}"
s = s.replace(old, new)

open(F, "w", encoding="utf-8").write(s)
print("OK  Future.wait -> Future.wait<dynamic>")
