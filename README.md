# Pehlwania Door Max & Interior — POS

Offline point-of-sale for **Pehlwania Door Max & Interior**: sales & quotations with
square-feet calculation (feet or inches), customer ledger (khata), payments,
order tracking, inventory, suppliers & purchases, daily and fixed monthly expenses,
reports, staff logins, design showcase, PDF bills and WhatsApp reminders.

One shared app, two ways to run it:

| | Android app (`app/`) | Desktop (`desktop/`) |
|---|---|---|
| Runs as | Flutter app (APK) showing the shared screens in a WebView | Single HTML file opened by `Open Pehlwania POS.bat` in Edge/Chrome |
| Data | **SQLite** on the phone (source of truth) | IndexedDB in the `AppData` folder |
| Backup / restore | Verified backup file (SAF), restore with preview + safety backup | Same file format |
| Google Sheets sync | Yes (offline-first queue) | No |
| Google Drive backup | Yes (optional) | No |
| Print / share | PDF bill → print, save, share to WhatsApp | Browser print (A4) |

Backup files are interchangeable: a desktop backup can be restored on Android and the
reverse; the original v2 desktop backups are accepted too.

## Repository layout
```
app/                      Flutter Android app
  assets/www/index.html   the shared POS screens (also the desktop source)
  assets/www/seed_gallery.js  showcase photos
  lib/data/               SQLite schema, migrations, record<->table mapping, money math
  lib/backup/             backup v3 build/validate/restore, Drive backup
  lib/sync/               Google auth (token), Sheets/Drive REST, sync engine
  lib/pdf/                PDF bill
  lib/bridge.dart         JavaScript <-> Dart bridge
  android/…/MainActivity.kt   Google authorization (Identity AuthorizationClient)
  test/                   unit tests (SQLite via FFI, fake Google Sheets server)
desktop/                  built single-file desktop app (python3 tools/build_desktop.py)
desktop-original/         the original v2 app, unchanged, for reference
web-tests/                Chromium tests (desktop mode) + Android emulator test
ci/                       CI helper scripts
docs/                     Google setup, spreadsheet layout, test report
```

## How data is kept safe
- **Every save goes to SQLite first, in one transaction.** A sale with its items,
  stock changes and advance payment is saved completely or not at all. Saving never
  waits for the internet.
- **Payments are separate rows** with their own IDs. Balance = bill total − payments.
  Tapping Save twice cannot create a second invoice or payment.
- **Agreed rates are stored on each bill line.** Changing a product rate (Rate Master,
  with history) never changes old bills.
- **Audit log** (SQLite `audit_log`): bills created/deleted (with totals and payments),
  payments added/changed/removed, rate changes, restores.
- **Migrations** are versioned and run in one transaction; if an upgrade fails the
  database is left as it was and the app shows a recovery screen (with "save a copy of
  the database file"). The database is never deleted or recreated automatically.
- **Backups** (`Backup & Sync` → Backup Data): complete JSON file with format version,
  schema version, record counts, money totals and a SHA-256 checksum. It is verified
  before success is reported. **Restore** validates the file (checksum, version, IDs,
  relationships, amounts), shows what is inside, needs explicit confirmation, writes a
  safety backup, replaces everything in one transaction, then verifies counts,
  relationships and totals — if verification fails the previous data is put back.
- **Google Sheets** is a copy for reports and cross-device viewing, not a backup.

> ⚠ If the app is uninstalled or its data is cleared, data on the phone is deleted.
> Recovery needs a backup file stored off the phone (Drive backup, WhatsApp to yourself,
> USB). Android's automatic Google backup of app data is also enabled as a best-effort
> extra, but it is not verified and must not be relied on.

## Google Sheets sync
Tabs: Customers, Orders, Order Items, Payments, Products & Rates, Daily Expenses,
Fixed Monthly Expenses, Sync Log — see [docs/SHEETS_SCHEMA.md](docs/SHEETS_SCHEMA.md).

- Save locally → commit → queue → push when online (on app open, on resume, when the
  internet returns, ~20 s after changes, or **Sync Now**).
- A queued change is marked synced **only after Google confirms the write**.
- Rows are matched by **record ID** (column A), re-read every run → retries never
  create duplicates. Deleted records are marked `Deleted = TRUE`.
- Errors: network/5xx/429 → kept and retried with exponential backoff (30 s … 6 h,
  with jitter, honours `Retry-After`); expired token → refreshed once; revoked access,
  deleted spreadsheet or changed headers → sync pauses with a clear message, nothing
  local is touched, nothing is recreated silently.
- Conflicts: if a row was edited in the sheet after the app last wrote it, orders,
  items and payments are **not** overwritten; Backup & Sync → *Resolve conflicts*
  (use phone data / keep sheet). For other tabs the phone wins and it is logged.

**Limits (by design):** sync is one-way phone → sheet (sheet edits are not imported);
Google Sheets has no transactions or unique constraints, so two phones editing the
*same* record at the same moment are detected as conflicts rather than prevented;
sync runs while the app is open (no background service).

Setup steps: [docs/GOOGLE_SETUP.md](docs/GOOGLE_SETUP.md).

## Build
Requirements: Flutter 3.47.x (Dart 3.13), JDK 17, Android SDK.
```bash
cd app
flutter pub get
flutter analyze
flutter test                     # needs libsqlite3 on Linux
flutter build apk --release      # signed if a release key is configured, see below
```
Release signing (never commit these): either environment variables
`ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, or a file
`app/android/key.properties`:
```
storeFile=/absolute/path/pehlwania-release.jks
storePassword=…
keyAlias=pehlwania
keyPassword=…
```
Without a key the release APK is signed with the debug key and must be treated as a test build.

Desktop single file: `python3 tools/build_desktop.py` → `desktop/PehlwaniaDoorMax-POS.html`.

## CI (GitHub Actions)
`.github/workflows/ci.yml` on every push:
1. desktop-mode tests in Chromium (`web-tests/desktop_e2e.mjs`);
2. `flutter analyze`, unit tests, release APK + CI test APK, APK verification
   (`aapt2 dump badging`, `apksigner verify`), release published as `build-N`;
3. Android emulator (API 34): installs the app, drives the real screens through the
   WebView, restarts the app, airplane mode, then installs and launches the release APK.

Repository secrets used: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`.
CI also writes its logs/results to `ci-reports/*` branches (CI output only).

## Install the APK on a phone
1. Download `PehlwaniaPOS-v…-release.apk` from the repository's **Releases** page.
2. Open it on the phone; if Android asks, allow *Install unknown apps* for the app you opened it from.
3. Install → open **Pehlwania POS** → log in `admin` / `admin` → change the password in *Users & Access*.
4. Moving from the PC: on the PC click **Backup**, send the file to the phone, then
   in the app *Backup & Sync → Restore Backup*.
5. Optional: Google Sheets / Drive — follow docs/GOOGLE_SETUP.md, then *Connect Google Account*.
