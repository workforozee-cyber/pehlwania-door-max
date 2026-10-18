// Android emulator end-to-end test of the REAL app (CI build with
// --dart-define=PDM_WEBVIEW_DEBUG=true so the WebView can be driven).
// One app session drives the screens (sales, payments, offline, print,
// backup to a file via Android's Save screen, restore via Android's Open screen);
// then the app is force-stopped and the SQLite database file itself is read from
// the device to prove the data is on disk, before and after relaunching.
import { _android as android } from 'playwright';
import { execSync } from 'node:child_process';
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const PKG = 'com.pehlwania.doormax';
const ACT = `${PKG}/com.pehlwania.pehlwania_pos.MainActivity`;
const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, 'android-shots'); fs.mkdirSync(shots, { recursive: true });
const results = []; let failed = 0;
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail: String(detail) }); if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const withTimeout = (p, ms, what) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms))]);

const [device] = await android.devices();
if (!device) { console.error('No Android device'); process.exit(2); }
console.log('device', device.model(), device.serial());
const sh = async c => (await device.shell(c)).toString().trim();
const shot = async name => { try { fs.writeFileSync(path.join(shots, name + '.png'), await device.screenshot()); } catch (e) {} };
const tapAny = async (sels, timeout = 6000) => { for (const sel of sels) { try { await device.tap(sel, { timeout }); return true; } catch (e) {} } return false; };

/** Copy the app's SQLite database (and WAL) from the device and run queries on it. */
function dbQuery(sqlByName) {
  const dir = fs.mkdtempSync(path.join(here, 'db-'));
  for (const f of ['pehlwania_pos.db', 'pehlwania_pos.db-wal', 'pehlwania_pos.db-shm', 'pehlwania_pos.db-journal']) {
    try { execSync(`adb exec-out run-as ${PKG} cat databases/${f} > "${path.join(dir, f)}"`, { stdio: ['ignore', 'ignore', 'ignore'] }); } catch (e) {}
    try { if (fs.statSync(path.join(dir, f)).size === 0) fs.unlinkSync(path.join(dir, f)); } catch (e) {}
  }
  const qf = path.join(dir, 'q.json'); fs.writeFileSync(qf, JSON.stringify(sqlByName));
  const pyf = path.join(dir, 'q.py');
  fs.writeFileSync(pyf, 'import sqlite3,json,sys\nc=sqlite3.connect(sys.argv[1])\nq=json.load(open(sys.argv[2]))\nprint(json.dumps({k:c.execute(v).fetchall() for k,v in q.items()}))\n');
  return JSON.parse(execSync(`python3 "${pyf}" "${path.join(dir, 'pehlwania_pos.db')}" "${qf}"`).toString());
}

async function attach() {
  await sh(`am start -W -n ${ACT}`);
  for (let i = 0; i < 30; i++) {
    try {
      const wv = await device.webView({ pkg: PKG }, { timeout: 8000 });
      const page = await withTimeout(wv.page(), 30000, 'attach to WebView page');
      await page.waitForFunction(() => typeof State !== 'undefined' && State.users && State.users.length > 0, null, { timeout: 60000 });
      return page;
    } catch (e) { console.log('waiting for WebView:', String(e).split('\n')[0]); await sleep(2000); }
  }
  throw new Error('WebView did not become ready');
}
async function login(page) {
  for (let attempt = 0; attempt < 5; attempt++) {
    await page.fill('#lg_user', 'admin'); await page.fill('#lg_pass', 'admin'); await page.click('.login-btn');
    try { await page.waitForFunction(() => document.body.classList.contains('authed'), null, { timeout: 8000 }); return; } catch (e) { await sleep(800); }
  }
  throw new Error('login failed');
}

const page = await attach();
const errs = []; page.on('pageerror', e => errs.push(String(e)));
await sleep(1500); await shot('01-login');
check('app starts and shows login (native SQLite mode)', await page.evaluate(() => IS_NATIVE === true));
await login(page); await sleep(800); await shot('02-dashboard');

// ---- sale in inches, double tap, payment, expense ----
await page.evaluate(async () => {
  Views.sales(); Views.itemAdd(); Views.itemPick(0, '2x2 PVC Ceiling');
  Views.itemSet(0, 'mu', 'in'); Views.itemSet(0, 'basis', 'sqft'); Views.itemSet(0, 'width', '36'); Views.itemSet(0, 'height', '84'); Views.itemSet(0, 'qty', '2'); Views.itemSet(0, 'rate', '500');
  Views.setAdvance('5000'); Views._draft.customerName = 'Emulator Customer';
});
await sleep(500); await shot('03-new-sale-inches');
await page.evaluate(async () => { await Promise.all([Views.saveDoc(false), Views.saveDoc(false)]); });
const inv = await page.evaluate(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return { n: State.documents.filter(x => x.customerName === 'Emulator Customer').length, grand: docTotals(d).grand, bal: docTotals(d).balance, no: d.no, id: d.id }; });
check('invoice saved once (double tap guarded)', inv.n === 1, JSON.stringify(inv));
check('inch calculation on device: 36×84 in ×2 @500 = 21,000; balance 16,000', inv.grand === 21000 && inv.bal === 16000);
await page.evaluate(async (id) => { Views.addPayment(id); document.querySelector('#p_amt').value = '6000'; await Views.savePayment(id); }, inv.id);
await page.evaluate(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '1500'; document.querySelector('#ex_cat').value = 'Bijli Ka Bill'; await Views.saveExpense(''); });
check('records are read back from native SQLite through the bridge', (await page.evaluate(async () => (await PDMNative.call('db.getAll', { store: 'documents' })).length)) === 1);

// ---- offline ----
await sh('cmd connectivity airplane-mode enable'); await sleep(3000);
await page.evaluate(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '700'; document.querySelector('#ex_cat').value = 'Chaye / Khana'; await Views.saveExpense(''); });
check('saving works in airplane mode', (await page.evaluate(() => State.expenses.length)) === 2);
const st = await page.evaluate(async () => PDMNative.call('sync.status'));
check('sync status: offline, Google not connected (no Google setup in CI)', st.online === false && (st.state === 'not_connected' || st.state === 'not_configured'), JSON.stringify({ online: st.online, state: st.state }));
check('changes are queued for Google Sheets while offline', st.pending > 0, `pending=${st.pending}`);
await page.evaluate(() => Nav.go('sync')); await sleep(1500); await shot('04-backup-sync-offline');
await sh('cmd connectivity airplane-mode disable'); await sleep(2000);

// ---- PDF bill: Android print preview ----
await page.evaluate(id => Print.doc(id), inv.id);
await sleep(7000); await shot('05-print-preview');
const printUi = Number(await sh('dumpsys activity activities | grep -i -c printspooler || true'));
check('PDF bill generated and Android print preview opened', printUi > 0, `printspooler entries=${printUi}`);
for (let i = 0; i < 3 && Number(await sh('dumpsys activity activities | grep -i -c printspooler || true')) > 0; i++) { await sh('input keyevent 4'); await sleep(2000); }

// ---- backup through Android's Save screen ----
await page.evaluate(() => Nav.go('sync')); await sleep(800);
const before = (await page.evaluate(async () => PDMNative.call('backup.status'))).lastSuccessAt || null;
page.evaluate(() => Backup.export()).catch(() => {});
await sleep(6000); await shot('06-android-save-screen');
const saved = await tapAny([{ text: /^save$/i }, { res: 'android:id/button1' }]);
await sleep(5000);
const bst = await page.evaluate(async () => PDMNative.call('backup.status'));
check('backup saved via Android file picker and verified', saved && bst.lastResult === 'success' && !!bst.lastSuccessAt && bst.lastSuccessAt !== before,
  JSON.stringify({ saved, result: bst.lastResult, file: bst.fileName, size: bst.sizeBytes, records: bst.records, error: bst.lastError }));
const downloads = await sh('ls /sdcard/Download/ 2>/dev/null');
check('backup file exists on phone storage', !!bst.fileName && downloads.includes(bst.fileName), downloads.split('\n').slice(-3).join(', '));

// ---- restore through Android's Open screen ----
await page.evaluate(async () => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); await DB.del('documents', d.id); await loadAll(); });
check('invoice deleted after the backup (restore must bring it back)', (await page.evaluate(() => State.documents.length)) === 0);
page.evaluate(() => Backup.pick()).catch(() => {});
await sleep(6000); await shot('07-android-open-screen');
let picked = await tapAny([{ text: bst.fileName || '__none__' }], 8000);
if (!picked) { await tapAny([{ desc: /show roots/i }], 3000); await sleep(1200); await tapAny([{ text: /^downloads$/i }], 3000); await sleep(1500); picked = await tapAny([{ text: bst.fileName || '__none__' }], 6000); }
check('backup file chosen in Android file picker', picked);
let restored = null;
if (picked) {
  await page.waitForSelector('#rs_ok', { timeout: 30000 }); await shot('08-restore-preview');
  check('restore preview shows the backup contents before changing anything', /Records in backup/.test(await page.textContent('#modal')));
  await page.check('#rs_ok');
  page.click('#rs_go').catch(() => {});
  await sleep(8000); await shot('09-restore-complete');
  await tapAny([{ text: /^ok$/i }], 20000); // "Restore complete and verified" dialog
  await sleep(4000);
  await page.waitForFunction(() => typeof State !== 'undefined' && State.users && State.users.length > 0, null, { timeout: 60000 });
  await login(page);
  restored = await page.evaluate(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return d ? { pays: d.payments.length, bal: docTotals(d).balance, exp: State.expenses.length } : null; });
}
check('full restore on device brings back the invoice, both payments and expenses', restored && restored.pays === 2 && restored.bal === 10000 && restored.exp === 2, JSON.stringify(restored));

// ---- every screen renders on the phone ----
for (const v of await page.evaluate(() => MODULES.map(m => m.k))) { await page.evaluate(x => Nav.go(x), v); await sleep(250); }
await page.evaluate(() => Nav.go('invoices')); await sleep(700); await shot('10-invoices');
await page.evaluate(() => Nav.go('expenses')); await sleep(700); await shot('11-expenses');
await page.evaluate(() => Nav.go('reports')); await sleep(700); await shot('12-reports');
check('all screens render on the phone without JavaScript errors', errs.length === 0, errs.slice(0, 3).join(' | '));

// ---- force-stop: data must be in the SQLite file on disk ----
await sh(`am force-stop ${PKG}`); await sleep(1500);
const q = {
  invoices: "SELECT no, grand_total FROM documents WHERE customer_name='Emulator Customer'",
  payments: "SELECT COUNT(*), SUM(amount) FROM payments p JOIN documents d ON d.id=p.document_id WHERE d.customer_name='Emulator Customer'",
  items: 'SELECT measure_unit, width, height, qty, rate, area_sqft, line_total FROM document_items',
  expenses: 'SELECT COUNT(*), SUM(amount) FROM expenses',
  queue: "SELECT COUNT(*) FROM sync_queue WHERE status='pending'",
  audit: 'SELECT action FROM audit_log ORDER BY id',
  integrity: 'PRAGMA integrity_check',
  fk: 'PRAGMA foreign_key_check',
};
let db1 = null;
try { db1 = dbQuery(q); } catch (e) { console.log('db read failed', String(e).slice(0, 300)); }
check('after force-stop: invoice is in the SQLite file with its total', db1 && db1.invoices.length === 1 && db1.invoices[0][1] === 21000, JSON.stringify(db1 && db1.invoices));
check('after force-stop: both payments (11,000) stored as separate rows', db1 && db1.payments[0][0] === 2 && db1.payments[0][1] === 11000, JSON.stringify(db1 && db1.payments));
check('after force-stop: item stored with inch unit, agreed rate and 21 sq ft area', db1 && db1.items.some(r => r[0] === 'in' && r[4] === 500 && Math.abs(r[5] - 21) < 1e-9 && r[6] === 21000), JSON.stringify(db1 && db1.items));
check('after force-stop: expenses (incl. the offline one) stored', db1 && db1.expenses[0][0] === 2 && db1.expenses[0][1] === 2200, JSON.stringify(db1 && db1.expenses));
check('database integrity and relationships OK', db1 && db1.integrity[0][0] === 'ok' && db1.fk.length === 0);
check('audit log recorded the restore', db1 && db1.audit.some(a => a[0] === 'restored'), JSON.stringify(db1 && db1.audit.slice(-5)));

// ---- relaunch: app opens the existing database (no reset) ----
await sh(`am start -W -n ${ACT}`); await sleep(12000); await shot('13-relaunched');
const pid = await sh(`pidof ${PKG}`);
await sh(`am force-stop ${PKG}`); await sleep(1500);
let db2 = null; try { db2 = dbQuery(q); } catch (e) {}
check('relaunch: app starts again and keeps all records', !!pid && db2 && JSON.stringify(db2.invoices) === JSON.stringify(db1 && db1.invoices) && db2.payments[0][0] === 2, `pid=${pid}`);

const crash = await sh('logcat -d -b crash');
check('no app crash in logcat', !crash.includes(PKG), crash.slice(0, 300));

fs.writeFileSync(path.join(here, 'android-results.json'), JSON.stringify({ at: new Date().toISOString(), device: device.model(), passed: results.length - failed, failed, results }, null, 2));
console.log(`\n${results.length - failed}/${results.length} passed`);
await device.close();
process.exit(failed ? 1 : 0);
