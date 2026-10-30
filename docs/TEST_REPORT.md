# Test report — v3.1.0 (build 21)

## v3.1.0 — material calculators, Save to Gallery, WhatsApp share (CI build 21, commit 4257e01)
| Area | Command | Result | Evidence |
|---|---|---|---|
| Calculator formulas (hand-worked expected quantities, validation, ft/in conversion) | `node web-tests/calc_engine_test.mjs` | **Passed 40/40** | `ci-reports/desktop: calc-engine.log` |
| Calculators screen in the app (all 7, 10×10 ft quantities, ft+in input, negative/empty rejected, PNG image, desktop save, WhatsApp text, add-to-quotation) + all earlier checks | `node web-tests/desktop_e2e.mjs` | **Passed 58/58** | `ci-reports/desktop: desktop-e2e.log` |
| Static analysis / Dart unit tests (unchanged features) | `flutter analyze`, `flutter test` | **Passed** (no issues) / **33/33** | `ci-reports/android` |
| Android emulator, real app (API 34) | `ci/emulator_test.sh` | **Passed 27/27** incl. media wall on device = 9 panels + 2 UV sheets; **Save to Gallery → PNG in MediaStore `Pictures/Pehlwania POS/` (image/png)**; **Share → Android share sheet** (WhatsApp is not installed on the emulator); all earlier checks (SQLite file after force-stop, offline, backup/restore, print) | `ci-reports/emulator` |
| Release APK v3.1.0 | `aapt2`, `apksigner` | **Passed** — versionCode 4, release key SHA-1 `1A:7E:25:…:28:0E` (same key → installs over 3.0.0 keeping data); SHA-256 `6fb20d4e336b9fb40bb92c8c78017d144011c26a3ac99bae117178bca57e54c4` | `badging.txt`, `signature.txt` |
| WhatsApp itself, Android 7–9 storage permission prompt, physical phone | manual | **Not run** (no WhatsApp / old Android in CI) | — |

Build 19 failed 8 emulator checks: the test read the backup status before the ~1.3 MB file had finished verifying (the file *was* saved). The test now waits for the status; build 21 passed everything.

---

## Earlier report — v3.0.0

All tests run automatically in GitHub Actions on every push (`.github/workflows/ci.yml`).
Results, logs, screenshots and the APK of the latest run are on the `ci-reports/*` branches.

## Summary

| Area | Command | Result | Evidence |
|---|---|---|---|
| Static analysis | `flutter analyze --no-fatal-infos` | **Passed** (0 errors, 0 warnings) | `ci-reports/android: analyze.log` |
| Dart unit tests (SQLite, money, atomic writes, migrations, backup/restore, Sheets sync with a simulated Google API, Drive) | `flutter test` | **Passed 33/33** | `ci-reports/android: unit-tests.log`, `test-results.json` |
| Shared UI, desktop mode (Chromium + IndexedDB) | `node web-tests/desktop_e2e.mjs` | **Passed 37/37** | `ci-reports/desktop: last-results.json` |
| Release APK build | `flutter build apk --release` | **Passed** | `build-release.log` |
| APK verification | `aapt2 dump badging`, `apksigner verify --print-certs` | **Passed** — see below | `badging.txt`, `signature.txt` |
| Android emulator (API 34, x86_64) — real app | `ci/emulator_test.sh` → `web-tests/android_e2e.mjs` | see "Emulator" below | `ci-reports/emulator` |
| Release APK install & launch on emulator | `adb install` + `am start` | **Passed** (process running, no crash) | `emulator-run.log`, screenshot `10-release-apk-running.png` |
| Real Google account: authorization, Sheets sync, Drive backup | manual (docs/GOOGLE_SETUP.md §8) | **Blocked** — needs Google Cloud OAuth client + test account | — |
| Physical Android phone, physical printer, WhatsApp share | manual | **Not run** | — |

## APK
| | |
|---|---|
| File | `PehlwaniaPOS-v3.0.0-release.apk` (≈59.0 MB, universal: arm64-v8a, armeabi-v7a, x86_64) |
| SHA-256 | `089a658ff774e8065f6a65cd79ee1bc2121d351468787f01d52297a5930bbb8c` (CI build 17, commit 23fe355) |
| Package / version | `com.pehlwania.doormax` · versionName 3.0.0 · versionCode 3 |
| SDK | minSdk 24 (Android 7.0) · targetSdk 36 · compileSdk 36 |
| Signing | **Release key** CN=Pehlwania Door Max · SHA-1 `1A:7E:25:F7:0A:81:55:F6:DD:A2:0B:D0:A5:1D:9A:59:74:E2:28:0E` (APK Signature Scheme v2) |
| Download | GitHub → Releases → latest `build-N` marked "(release)" |

## Emulator (real APK, Android 14) — checks
Build 17 (final): **23/23 passed**, and the release APK installs, launches and keeps running. Build 16 was also 23/23. Earlier run 14 failed only the offline-status check
because the emulator's virtual Wi-Fi stayed on in airplane mode; the test now also turns Wi-Fi/data off.
In build 16 the separate release-APK launch check found the app killed by Android because Google Play services
restarted on the emulator ("depends on provider … in dying proc com.google.android.gms.persistent"); the same check
passed in builds 7, 11 and 14, and CI now relaunches once in that case.

- app starts in native SQLite mode · invoice saved once on double tap · 36×84 in ×2 @500 = 21,000 · bridge reads back from SQLite
- saving in airplane mode · changes queued for Sheets while offline
- PDF bill → Android print preview opens
- **Backup Data** through Android's *Save* screen → status "success", file in Downloads (1.29 MB, 63 records)
- invoice deleted → **Restore Backup** through Android's *Open* screen → preview → confirm → invoice + 2 payments + expenses back
- all screens render without JavaScript errors
- after **force-stop**, the SQLite *file* contains: the invoice (21,000), 2 payment rows (11,000), the item (unit `in`, rate 500, 21 sq ft), 2 expenses (2,200); `PRAGMA integrity_check` ok; no FK violations; audit log has `restored`
- after restart the app shows the same invoice, payments and expenses · no crash in logcat

## Dart unit tests (33)
- backup_test.dart: a restore that fails half-way leaves the previous data intact
- backup_test.dart: backup status keeps the last success when a later attempt fails
- backup_test.dart: backup v3 contains every store, correct counts, totals and a valid checksum
- backup_test.dart: corrupted, edited and unsupported files are rejected before anything changes
- backup_test.dart: full restore replaces everything, verifies, and makes a safety backup first
- backup_test.dart: original desktop (v2) backup files restore, older items get stable IDs
- data_test.dart: financial integrity changing a product rate never changes existing invoices (historical rate kept)
- data_test.dart: financial integrity older lines without item/payment IDs get stable IDs on first save
- data_test.dart: financial integrity payments are separate rows; re-saving with the same payment ID never duplicates it
- data_test.dart: financial integrity unchanged re-save does not queue anything for sync
- data_test.dart: persistence & round-trip a failing write rolls back the whole batch (atomic)
- data_test.dart: persistence & round-trip delete invoice removes items & payments, queues sheet deletions and keeps an audit record
- data_test.dart: persistence & round-trip invalid records are rejected with a clear message
- data_test.dart: persistence & round-trip invoice with items + payments round-trips exactly (extra fields kept)
- data_test.dart: persistence & round-trip money math matches the app: inches ÷144, feet unchanged, discount & tax
- data_test.dart: schema & migrations fresh database is created at the current schema version with integrity ok
- data_test.dart: schema & migrations reopening keeps data; opening with an OLDER app version is refused without changes
- sync_test.dart: Drive backup uploads a verified, restorable backup
- sync_test.dart: Google sign-in not configured: clear state, app keeps working
- sync_test.dart: Sync Log tab gets a summary row; tokens never appear in logs
- sync_test.dart: a financial row edited in the sheet is a conflict and is not overwritten until resolved
- sync_test.dart: after a restore nothing is duplicated in the sheet
- sync_test.dart: changes made offline are kept and synced when internet returns
- sync_test.dart: creates all tabs with the documented headers; rows matched by ID
- sync_test.dart: deleted records are marked Deleted, not removed; missing sheet row never deletes local data
- sync_test.dart: expired token: refreshed once automatically
- sync_test.dart: lost response after append does not create duplicates on retry
- sync_test.dart: non-financial conflict: phone wins and the event is logged
- sync_test.dart: rate limit (429) on write: kept for retry with backoff; last success time not updated
- sync_test.dart: revoked access / deleted spreadsheet: local data and queue kept, clear status
- sync_test.dart: server error on the first request: nothing lost, retried next time
- sync_test.dart: switching to a different spreadsheet uploads everything again, matched by ID
- sync_test.dart: updates change the existing row; payments are one row each, never duplicated

## Desktop-mode tests (37)
Upgrade from the original v2 app's real IndexedDB data (totals unchanged, new store added, spec products added without removing
originals) · inch and feet totals · one invoice on double tap · item/payment IDs · payment not duplicated on double tap ·
balance = total − payments · rate change keeps old invoice rate · failed multi-step save rolls back · daily + fixed expenses ·
fixed costs in report · data survives reload · backup v3 header, independent SHA-256 check, counts, contents, status ·
corrupted and future-version files rejected with no Restore button · safety backup downloaded before restore ·
replace-all restore with payments, rates, fixed expenses · v2 backup restore · all screens render · 380 px phone width without overflow.

## Not covered / blocked
- Real Google authorization, Sheets writes and Drive upload (needs Google Cloud setup) — logic covered by the simulated API tests.
- Two physical phones syncing to one sheet at the same time.
- Physical printer output, WhatsApp share sheet with WhatsApp installed.
