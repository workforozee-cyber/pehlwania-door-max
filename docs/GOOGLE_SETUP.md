# Google Sheets sync & Drive backup — one-time setup

The Android app talks to Google with **short-lived OAuth access tokens** issued by
Google Play services on the phone. No client secret, service-account key, password
or token is stored in the app or this repository. Google identifies the app by:

| Item | Value |
|---|---|
| Android package name | `com.pehlwania.doormax` |
| Release signing certificate SHA-1 | `1A:7E:25:F7:0A:81:55:F6:DD:A2:0B:D0:A5:1D:9A:59:74:E2:28:0E` |
| Release signing certificate SHA-256 | `FD:FA:52:E7:3F:D3:01:98:1E:9D:4B:5B:52:1B:08:90:45:04:3F:25:12:E8:5A:EB:2F:90:28:97:37:0C:05:43` |

> The SHA-1 above belongs to the release key (`pehlwania-release.jks`, kept by the
> owner, **not** in git). The app also shows the SHA-1 of the APK it is running in
> **Backup & Sync** when Google is not set up — use that value if you sign with a
> different key. Debug/test APKs have a different SHA-1 and need their own client.

Until these steps are done the app shows **"Google not set up"** in Backup & Sync.
Everything else (sales, payments, expenses, backups to a file) works fully offline.

## 1. Google Cloud project
1. Open <https://console.cloud.google.com/> with the shop's Google account.
2. Create a project, e.g. **Pehlwania POS**.

## 2. Enable the APIs
APIs & Services → Library → enable:
- **Google Sheets API**
- **Google Drive API** (used for creating the spreadsheet, reading the account email and Drive backups)

## 3. OAuth consent screen (Google Auth Platform)
1. APIs & Services → OAuth consent screen (Google Auth Platform → Branding/Audience).
2. User type **External** (or Internal for a Google Workspace organisation).
3. App name *Pehlwania POS*, support email, developer email.
4. **Data access / scopes**: add
   - `https://www.googleapis.com/auth/spreadsheets`
   - `https://www.googleapis.com/auth/drive.file`
5. **Audience → Test users**: add every Google account that will sign in (e.g. the
   shop's Gmail). While the app is in *Testing* only these accounts can connect, and
   Google may ask them to re-consent every 7 days. For permanent use, *Publish app*
   (the `spreadsheets` scope is "sensitive": Google may require verification for
   public apps; for a single shop, staying in Testing with listed test users works).

## 4. Android OAuth client
1. APIs & Services → Credentials → **Create credentials → OAuth client ID**.
2. Application type **Android**.
3. Package name `com.pehlwania.doormax`, SHA-1 from the table above.
4. Create. (No JSON file needs to be downloaded or added to the app.)

## 5. Connect in the app
1. Install the **release** APK (signed with the key whose SHA-1 you registered).
2. Menu → **Backup & Sync** → **Connect Google Account** → choose the account → allow.
3. Choose **Create new spreadsheet** (the app creates *“Pehlwania Door Max — Business
   Records”* with all tabs) or **Use existing spreadsheet** (paste its link; the
   account must have edit access; other tabs in it are left alone).
4. Tap **Sync Now**. The status shows the last successful sync, pending and failed counts.

## 6. Spreadsheet permissions
- The spreadsheet is created in the connected account's Drive and is **private**.
- Share it (Share button in Google Sheets) only with people who need to see it —
  prefer **Viewer** access. Anyone with Editor access can change rows; the app will
  detect edits to orders, items and payments as *conflicts* and will not overwrite
  them silently (see Backup & Sync → Resolve conflicts).
- Do not rename tabs or change the header row. If it happens the app pauses that tab
  and shows "Sheet columns changed" until the header row is restored
  (see [SHEETS_SCHEMA.md](SHEETS_SCHEMA.md)).

## 7. Quotas
Sheets API default quota is 300 read and 300 write requests per minute per project,
60 per minute per user. The app batches writes (one request per tab per sync run) and
backs off automatically on HTTP 429, so a normal shop stays far below this.

## 8. Testing checklist (with a TEST spreadsheet, not the real one)
- [ ] Connect account → state *Connected*, account email shown.
- [ ] Create spreadsheet → 8 tabs with headers.
- [ ] Airplane mode on → create invoice + payment + expense → "saved on this device · sync pending".
- [ ] Airplane mode off → within ~1 minute rows appear; *Waiting to sync* returns to 0.
- [ ] Add another payment to the same invoice → one new Payments row, Orders row updated (not duplicated).
- [ ] Edit a Grand Total cell in the sheet, then change that invoice on the phone → *Conflicts: 1*; resolve.
- [ ] Remove the account's access to the sheet → *No permission*, data still on phone; restore access → syncs.
- [ ] Back up to Drive → file appears in "Pehlwania POS Backups"; *Restore from Drive* shows it.

## Backend
No backend server is used. All sync logic runs on the phone (see the limits in
the README: one-way phone → sheet; Google Sheets has no transactions).
