# Opstation — Flutter App

Multi-tenant field operations and delivery management app. Flutter codebase that targets Android, iOS, and Web (single codebase for mobile + admin panel).

This repository is **Slice 1** of a phased build. It contains the project foundation: theme, routing, authentication shell, and polished home screens for all six roles. The salesperson flow, offline sync, customer management, admin dashboard details, delivery module, and reports will be built in subsequent slices.

---

## Getting started

### Prerequisites

- Flutter SDK 3.19 or newer (`flutter --version` to check).
- Dart 3.3 or newer.
- For mobile builds: Android Studio (with Android SDK) and/or Xcode.
- For web builds: Chrome.

### First-time setup

These project files contain only the `lib/`, `pubspec.yaml`, and `analysis_options.yaml`. The native platform folders (`android/`, `ios/`, `web/`, etc.) need to be generated once.

From the project root:

```bash
# Generate the native platform scaffolding.
flutter create . --project-name opstation --org app.opstation

# Install dependencies.
flutter pub get

# Optional — run static analysis.
flutter analyze
```

### Run

```bash
# Mobile (connected device or emulator)
flutter run

# Web
flutter run -d chrome
```

### Sign in (Slice 1 uses mock auth)

All demo accounts accept **any non-empty password** (default: `password`). The email determines which role's home screen loads. On the login screen, tap any role pill to autofill.

| Role | Email |
|---|---|
| Super Admin | `superadmin@opstation.app` |
| Master Admin | `master@opstation.app` |
| Admin | `admin@opstation.app` |
| Salesperson | `hamza@opstation.app` |
| Surveyor | `surveyor@opstation.app` |
| Dispatch Manager | `dispatch@opstation.app` |
| Driver | `driver@opstation.app` |

---

## Architecture

```
lib/
├── main.dart                 # Entry point, wraps app in ProviderScope
├── app.dart                  # MaterialApp.router wiring theme + router
│
├── core/
│   ├── theme/                # Colors, theme, dark/light controller
│   ├── router/               # go_router config with role-based redirects
│   ├── api/                  # (reserved) API client — backend wiring
│   └── constants/            # (reserved) app-wide constants
│
├── features/
│   ├── auth/
│   │   ├── models/           # UserRole enum, AuthUser
│   │   ├── data/             # MockAuthRepository (will be swapped for real API)
│   │   ├── providers/        # AuthController (AsyncNotifier)
│   │   └── presentation/     # Splash, Login screens
│   │
│   ├── salesperson/          # Salesperson role features
│   ├── admin/                # Admin role features
│   ├── master_admin/         # Master Admin role features
│   ├── surveyor/             # Surveyor role features
│   ├── dispatch_manager/     # Dispatch Manager role features
│   └── driver/               # Driver role features
│
└── shared/
    └── widgets/              # Reusable UI: header, cards, tiles, badges
```

### Core choices

- **State management:** [Riverpod 2](https://riverpod.dev) — `Notifier` / `AsyncNotifier` pattern.
- **Routing:** [go_router](https://pub.dev/packages/go_router) with auth-driven redirect.
- **Theme:** Light and dark modes with flat surfaces, no gradients. Primary blue `#2563EB`, success green `#10B981`, matching the existing Opstation app screenshots.
- **Typography:** Google Fonts Inter.
- **HTTP client (ready for Slice 2+):** Dio.
- **Persistence:** Currently in-memory. SharedPreferences scaffolded for simple prefs; a proper local DB (Drift) is deferred by request.

### Feature module template

Each feature module follows the same internal layout:

```
features/<feature>/
├── models/         Plain Dart data classes.
├── data/           Repositories — mock now, real API later.
├── providers/      Riverpod state holders.
└── presentation/   Screens and feature-specific widgets.
```

---

## Slice roadmap

| Slice | Scope | Status |
|---|---|---|
| 1 | Foundation — theme, routing, auth shell, role home placeholders | ✅ this build |
| 2 | Salesperson core flow — Home → Route in progress → Mark Visit → Complete route → Export | Next |
| 3 | Offline storage + sync queue + late-sync verification | Deferred |
| 4 | Customer management — list, search, filters, location wizard | |
| 5 | Admin dashboard — live monitoring map, salesperson ranking, reports | |
| 6 | Delivery module — driver routes, photo proof, COD | |
| 7 | PDF reports matching Visit Report and Trip Summary samples | |

---

## Development notes

- **Mock auth:** `features/auth/data/mock_auth_repository.dart` — replace with real repository once backend API details are shared. The `AuthController` interface will stay the same.
- **Theme toggle:** In-memory only. Persistence via `SharedPreferences` is a small add in Slice 2.
- **Role routing:** `core/router/app_router.dart` handles redirecting unauthenticated users to `/login` and logged-in users to their role's home. Per-route role enforcement is noted as a TODO for Slice 2.
- **Sound toggle in the header:** The icon is wired but currently a visual placeholder; hook into audio services when visit confirmations and other sounds are added.
- **New items surfaced from screenshots** (Skip action, photos on visits, spoofing detection, reimbursement signoff, salesperson ranking, Excel exports) are **not yet built**. Raise these as a requirements delta before Slice 2 if you want them included from the start.

---

## Known gaps before production

- No real API client — all data is in-memory mock.
- No push notification setup (FCM / APNs).
- No Google Maps integration (customer location wizard).
- No Drive OAuth for photo storage.
- No PDF generation.
- No connectivity / sync status listener in the header.
- Auth tokens not persisted.

These are intentional for Slice 1 and are picked up in the later slices.
