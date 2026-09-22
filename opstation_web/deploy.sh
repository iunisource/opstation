#!/bin/bash
set -e
grab () {
  src="$(ls -t ~/Downloads/$1*.dart 2>/dev/null | head -1)"
  if [ -n "$src" ]; then cp "$src" "$2"; echo "copied $(basename "$src") -> $2"; fi
}
grab org_access_screen         lib/features/settings/presentation/org_access_screen.dart
grab dashboard_screen          lib/features/dashboard/presentation/dashboard_screen.dart
grab app_router                lib/core/router/app_router.dart
grab main_layout               lib/core/layout/main_layout.dart
grab auth_controller           lib/features/auth/auth_controller.dart
grab erp_job_card_screen       lib/features/erp/presentation/erp_job_card_screen.dart
grab erp_customer_360_screen   lib/features/customers/presentation/erp_customer_360_screen.dart
grab erp_fg_without_bom_screen lib/features/erp/presentation/erp_fg_without_bom_screen.dart

flutter build web --release --no-web-resources-cdn --source-maps
firebase deploy --only hosting
git add -A
git commit -m "Deploy: account linking + Active Routes visit-status split + pending UI fixes"
git push origin main
echo "=== git status (should be clean) ==="
git status --short
