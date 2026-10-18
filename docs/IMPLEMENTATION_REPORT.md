# Implementation report — Pehlwania Door Max & Interior POS v3.0.0

Date: 18 Oct 2026 · Repository: `workforozee-cyber/pehlwania-door-max` (private) · Branch: `main`

## A. Existing architecture (as found)
- **What existed:** `Downloads\Pehlwania-POS\Pehlwania POS\` — a single 1.4 MB HTML file
  (`PehlwaniaDoorMax-POS.html`, "v2") plus a `.bat` launcher that opens it in an Edge/Chrome
  app window with its own profile folder (`AppData`). No Android app, no git repository,
  no build system, no tests.
- **Stack:** vanilla JavaScript, no framework; data in **IndexedDB** (`pehlwania_pos`, version 3)
  with 11 object stores (settings, products, customers, documents, counters, users,
  suppliers, purchases, expenses, stockmoves, gallery); 24 showcase photos embedded as base64.
- **Features:** login with staff permissions, dashboard, New Sale/Invoice & Quotation (W×H in
  **feet**, per-piece or per-sq-ft pricing, discount, tax %, advance), invoice list with payments,
  order board (Pending → In Process → Ready → Delivered), inventory with stock log, suppliers &
  purchase bills, expenses by category, reports (sales, P&L, cash flow, receivable/payable by
  date range & branch), branches, A4 print, JSON backup/restore, showcase/slideshow.
- **Business rules found (kept unchanged):** line amount = rate × qty (per piece) or
  rate × W × H × qty (per sq ft); taxable = max(0, subtotal − discount); tax = round(taxable × tax%);
  grand = taxable + tax; balance = grand − Σ payments; status Paid/Partial/Unpaid.
- **Client spec (PDF):** asked for inches → sq ft (W×H÷144×qty), the product list, customer ledger,
  PDF bill to WhatsApp, payment reminders, expense categories, admin rate master, offline,
  Flutter/React Native with SQLite/Hive.
- **Constraints found:** existing data lives only in IndexedDB on the PC; the original backup
  had no checksum or validation; restore cleared stores one by one (not atomic); payments had
  no IDs; saving an invoice was several separate writes; a "re-seed products" check would have
  wiped product rates once the seed version changed; narrow-screen CSS hid the menu icons.

**Approach chosen:** keep the existing screens and logic (shared HTML), add a Flutter Android
shell with SQLite as the source of truth behind a JavaScript bridge, keep the desktop version
working from the same source.

## B. Important files
| File | Change |
|---|---|
| `app/assets/www/index.html` | Shared UI. New storage adapter (IndexedDB on desktop / native SQLite on Android) with atomic `DB.tx`; UUID IDs; payment & item IDs; double-submit guards; feet/inch per line; fixed monthly expenses; spec products & expense categories; rate history; backup v3 + validation + preview + safety backup; Backup & Sync screen; PDF print/share & WhatsApp reminder hooks; phone layout; bug fixes (IndexedDB abort on error, product re-seed, hidden icons, login field clearing) |
| `app/lib/data/schema.dart` | SQLite schema v1 (16 business tables + audit/sync tables), FKs, CHECKs, indexes; migration framework |
| `app/lib/data/app_database.dart` | Open/migrate in one transaction, integrity check, refuse downgrade, never delete |
| `app/lib/data/store_defs.dart` | Record ↔ table mapping (typed columns + `extra` JSON so nothing is lost) |
| `app/lib/data/repository.dart` | Atomic batches, child rows (items/payments) diffing, sync queue, audit log, consistent export, replace-all |
| `app/lib/data/money.dart` | Exact port of the JS money math |
| `app/lib/backup/backup_service.dart` | Backup v3 build/validate (also v2), safety backup, atomic restore + verification + automatic undo |
| `app/lib/backup/drive_backup.dart` | Optional Google Drive backup (upload with MD5 check, list, download→validate→restore) |
| `app/lib/sync/*` | Google token channel, Sheets/Drive REST client, tab schema, sync engine |
| `app/lib/bridge.dart`, `app/lib/main.dart` | WebView host, JS bridge, lifecycle/connectivity sync triggers, dialogs, back button, file chooser, DB error screen |
| `app/lib/pdf/bill_pdf.dart` | A4 PDF bill with logo, branch address & phone |
| `app/android/.../MainActivity.kt` | Google Identity AuthorizationClient (OAuth tokens, no secrets) |
| `app/android/app/build.gradle.kts`, manifest | App ID `com.pehlwania.doormax`, release signing from env/key.properties, permissions, Play services auth |
| `app/test/*` | 33 Dart tests incl. a fake Google Sheets/Drive server |
| `web-tests/desktop_e2e.mjs` | 37 Chromium checks (desktop mode) |
| `web-tests/android_e2e.mjs`, `ci/emulator_test.sh` | Emulator test of the real APK |
| `.github/workflows/ci.yml` | Tests, build, APK verification, release, emulator |
| `desktop/` | v3 desktop single file (built by `tools/build_desktop.py`) |
| `desktop-original/` | Original v2 app, unchanged |
| `README.md`, `docs/*` | Build, setup, schema, limitations, this report |

## C. Database and financial integrity
- **SQLite** (`sqflite`), file `pehlwania_pos.db`, `PRAGMA foreign_keys=ON`, schema version 1.
  Orders (`documents`) → `document_items` (agreed rate, W, H, unit ft/in, qty, area, line total)
  → `payments` (one row each, `amount > 0`), with `ON DELETE CASCADE`; purchases likewise;
  `UNIQUE(type, no)` for bill numbers; indexes on customer, date and parent IDs.
- **Persistence:** every UI write goes through one `db.batch` call = one SQLite transaction.
  A sale (counter, invoice, items, payment, stock changes, stock log) is all-or-nothing.
  Unchanged re-saves write nothing and queue nothing.
- **Historical pricing:** the agreed rate is stored on each line; product rate changes are kept
  in `rateHistory` and the audit log and never touch existing bills (tested).
- **Payments & balances:** balance = grand total − Σ payment rows. Payment IDs make retries and
  double taps idempotent (tested). Deleting an invoice records its totals and payments in `audit_log`.
- **Migrations:** run inside one transaction with FK check; failure → old database untouched,
  recovery screen with "save a copy of the database file"; downgrade refused. The previous
  "schema" is the desktop IndexedDB/v2 backup — migration path: restore the v2/v3 backup file
  (tested with real files produced by the original app).

## D. Backup and restoration
- **Format:** `pehlwania-pos-backup` v3 JSON: format/app/schema versions, creation time, record
  counts per store, invoice & payment totals, SHA-256 of the exact payload text, payload with all
  stores (customers, orders+items+payments, products+rate history, purchases, expenses, fixed
  expenses, stock log, gallery, settings, users, counters). No tokens or Google credentials.
  Note: staff login password *hashes* are included so logins work after restore.
- **Validation:** checksum, version, IDs present/unique (records, items, payments), types,
  amounts, required settings, customer/supplier links (warnings), owner login (warning).
- **Policy:** documented **replace-all**. Preview + explicit confirmation → safety backup
  (Android: app folder, newest 5 kept; desktop: downloaded file) → one transaction → verify
  counts, FK check, money totals → on failure the safety backup is restored automatically.
  Sync metadata is reset so restored data is re-uploaded by ID and never falsely marked synced.
- **Verified by tests:** export/validate, corrupted/edited/truncated/unsupported/duplicate-ID
  rejection, full restore, failure half-way leaves data intact, v2 restore, status keeps last success
  (Dart + Chromium); on-device SAF save + restore in the emulator test (see F).

## E. Google integration
- **Tabs:** Customers, Orders, Order Items, Payments, Products & Rates, Daily Expenses, Fixed
  Monthly Expenses, Sync Log — columns in `docs/SHEETS_SCHEMA.md`, validated before writing.
- **Auth:** Android Google Identity *AuthorizationClient* → short-lived access tokens for
  `spreadsheets` + `drive.file`; no secrets in the APK; token refreshed once on 401; NEEDS_UI →
  user must reconnect.
- **Queue & retry:** one durable row per record (`sync_queue`), statuses pending / failed /
  conflict; removed only after Google confirms the write; exponential backoff 30 s → 6 h with
  jitter, honours `Retry-After`; triggers: app open, resume, connectivity restored, 20 s after
  changes, Sync Now, Retry failed.
- **Duplicates:** ID column re-read every run; retries update in place (tested with a lost
  append response). Deletes mark `Deleted=TRUE`.
- **Conflicts:** row hash vs last pushed hash; financial tabs → conflict, never auto-overwritten;
  other tabs → phone wins + logged. Missing sheet row never deletes local data.
- **Status:** Google Sheets sync — **implemented, tested against a simulated Sheets API, awaiting
  Google Cloud configuration and a real-account test**. Google Drive backup — **implemented,
  tested against a simulated Drive API, awaiting configuration and a real-account test**.
  No real Google authorization was performed (no Google Cloud project/credentials available here).

## F. Tests and build
See [TEST_REPORT.md](TEST_REPORT.md) for the table with commands and evidence.

## G. GitHub
See TEST_REPORT.md (repository URL, branch, commit, CI run, release).

## H. Outstanding configuration
1. **GitHub secrets** `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD` (from the key files
   delivered to the owner) → CI then produces a release-signed APK with SHA-1 `1A:7E:25:…:28:0E`.
2. **Google Cloud** project, Sheets + Drive APIs, OAuth consent (test users), Android OAuth client
   for `com.pehlwania.doormax` + release SHA-1 — step by step in `docs/GOOGLE_SETUP.md`.
3. Connect the account in the app, create/select the spreadsheet, run the checklist in GOOGLE_SETUP.md
   with a **test** spreadsheet first.
4. Keep the signing key safe (two copies); without it updates cannot be installed over the app.
5. No backend server is needed.

## I. Limitations and next steps
- Sheets sync is **one-way** (phone → sheet). Sheet edits are not imported; two phones editing the
  *same* record are detected as conflicts, not merged. A backend would be needed for true
  multi-device two-way sync.
- Sync runs while the app is open (no background WorkManager job): background Google
  authorization from a headless engine was not implemented to avoid untested behaviour.
- Real Google authorization, real Sheets/Drive calls and a physical-phone test have **not** been
  run. Physical printers were not tested (the Android print preview opens in the emulator test).
- Staff passwords use the original app's simple hash (kept for compatibility with existing
  logins); it protects against casual access only.
- "Erase ALL data" leaves already-synced rows in the spreadsheet (they are not marked deleted).
- Image picking in the showcase on Android uses a temporary copy; very large photos are
  downscaled by the page as before.
