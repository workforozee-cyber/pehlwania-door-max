// Android emulator end-to-end test of the REAL app (APK built with
// --dart-define=PDM_WEBVIEW_DEBUG=true so the WebView can be driven).
// Verifies the native SQLite bridge: create data, restart the app, airplane
// mode, invoice/payment math, and that data survives a force-stop.
// Run in CI after `adb install`. Writes screenshots to web-tests/android-shots/.
import { _android as android, chromium } from 'playwright';
import { execSync } from 'node:child_process';
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const PKG = 'com.pehlwania.doormax';
const ACT = `${PKG}/com.pehlwania.pehlwania_pos.MainActivity`;
const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, 'android-shots'); fs.mkdirSync(shots, { recursive: true });
const results = []; let failed = 0;
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail }); if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

const [device] = await android.devices();
if (!device) { console.error('No Android device'); process.exit(2); }
console.log('device', device.model(), device.serial());
const sh = async c => (await device.shell(c)).toString().trim();

const withTimeout = (p, ms, what) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms))]);
let cdpPort = 9300, browser = null;
/** Start the app (if needed) and attach to its WebView through Chrome DevTools,
 *  using a fresh port for each process so a killed process is never reused. */
async function launch() {
  console.log('launching', new Date().toISOString());
  await sh(`am start -W -n ${ACT}`);
  for (let i = 0; i < 40; i++) {
    try {
      const pid = Number(await sh(`pidof ${PKG}`));
      if (!pid) throw new Error('app process not running yet');
      const sock = `webview_devtools_remote_${pid}`;
      if (!(await sh('cat /proc/net/unix')).includes(sock)) throw new Error('WebView DevTools socket not open yet');
      if (browser) { try { await withTimeout(browser.close(), 5000, 'close old CDP'); } catch (e) {} browser = null; }
      const port = ++cdpPort;
      execSync(`adb forward tcp:${port} localabstract:${sock}`);
      browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`, { timeout: 15000 });
      const ctx = browser.contexts()[0];
      const page = ctx.pages().find(p => p.url().includes('index.html')) || await ctx.waitForEvent('page', { timeout: 15000 });
      await page.waitForFunction(() => typeof State !== 'undefined' && State.users && State.users.length > 0, null, { timeout: 60000 });
      console.log(`WebView ready (pid ${pid}, port ${port})`);
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
async function shot(name) { const b = await device.screenshot(); fs.writeFileSync(path.join(shots, name + '.png'), b); }

let page = await launch();
await sleep(1500); await shot('01-login');
check('app starts and shows login (native mode)', await page.evaluate(() => IS_NATIVE === true));
await login(page); await sleep(800); await shot('02-dashboard');

// ---- create data through the real UI code paths ----
await page.evaluate(async () => {
  Views.sales(); Views.itemAdd(); Views.itemPick(0, '2x2 PVC Ceiling');
  Views.itemSet(0, 'mu', 'in'); Views.itemSet(0, 'basis', 'sqft'); Views.itemSet(0, 'width', '36'); Views.itemSet(0, 'height', '84'); Views.itemSet(0, 'qty', '2'); Views.itemSet(0, 'rate', '500');
  Views.setAdvance('5000'); Views._draft.customerName = 'Emulator Customer';
});
await sleep(500); await shot('03-new-sale-inches');
await page.evaluate(async () => { await Promise.all([Views.saveDoc(false), Views.saveDoc(false)]); });
const inv = await page.evaluate(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return { n: State.documents.filter(x => x.customerName === 'Emulator Customer').length, grand: docTotals(d).grand, bal: docTotals(d).balance, no: d.no }; });
check('invoice saved once in SQLite (double tap guarded)', inv.n === 1, JSON.stringify(inv));
check('inch calculation on device: 21,000 total, 16,000 balance', inv.grand === 21000 && inv.bal === 16000);
await page.evaluate(async (no) => { const d = State.documents.find(x => x.no === no); Views.addPayment(d.id); document.querySelector('#p_amt').value = '6000'; await Views.savePayment(d.id); }, inv.no);
await page.evaluate(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '1500'; document.querySelector('#ex_cat').value = 'Bijli Ka Bill'; await Views.saveExpense(''); });
const nativeRows = await page.evaluate(async () => (await PDMNative.call('db.getAll', { store: 'documents' })).length);
check('records are read back from native SQLite', nativeRows === 1);

// ---- restart: force-stop the process and reopen ----
await sh(`am force-stop ${PKG}`); await sleep(1500);
page = await launch(); await login(page);
const after = await page.evaluate(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return d ? { pays: d.payments.length, bal: docTotals(d).balance, exp: State.expenses.length } : null; });
check('data survives force-stop + restart', after && after.pays === 2 && after.bal === 10000 && after.exp === 1, JSON.stringify(after));

// ---- offline ----
await sh('cmd connectivity airplane-mode enable'); await sleep(2500);
await page.evaluate(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '700'; document.querySelector('#ex_cat').value = 'Chaye / Khana'; await Views.saveExpense(''); });
const offExp = await page.evaluate(() => State.expenses.length);
check('saving works in airplane mode', offExp === 2);
await page.evaluate(() => Nav.go('sync')); await sleep(1500); await shot('04-backup-sync-offline');
const st = await page.evaluate(async () => PDMNative.call('sync.status'));
check('sync status reports offline and not connected (no Google setup in CI)', st.online === false && (st.state === 'not_connected' || st.state === 'not_configured'), JSON.stringify({ online: st.online, state: st.state, pending: st.pending }));
check('changes are queued for Google Sheets while offline', st.pending > 0, `pending=${st.pending}`);
await sh(`am force-stop ${PKG}`); await sleep(1000);
page = await launch(); await login(page);
check('offline changes survive restart', (await page.evaluate(() => State.expenses.length)) === 2);
await sh('cmd connectivity airplane-mode disable');

// ---- PDF bill: print preview opens (Android print framework) ----
const invId = await page.evaluate(() => State.documents.find(x => x.customerName === 'Emulator Customer').id);
await page.evaluate(id => Print.doc(id), invId);
await sleep(6000); await shot('08-print-preview');
const printUi = await sh('dumpsys activity activities | grep -i -c printspooler || true');
check('PDF bill generated and Android print preview opened', Number(printUi) > 0, `printspooler activities=${printUi}`);
await sh('input keyevent 4'); await sleep(2000);
if (Number(await sh('dumpsys activity activities | grep -i -c printspooler || true')) > 0) { await sh('input keyevent 4'); await sleep(1500); }

// ---- backup to a file through Android's Save screen, then full restore ----
const tapAny = async (sels, timeout = 6000) => { for (const sel of sels) { try { await device.tap(sel, { timeout }); return true; } catch (e) {} } return false; };
await page.evaluate(() => Nav.go('sync')); await sleep(800);
const before = (await page.evaluate(async () => PDMNative.call('backup.status'))).lastSuccessAt || null;
page.evaluate(() => Backup.export()).catch(() => {});
await sleep(5000); await shot('09-android-save-screen');
const saved = await tapAny([{ text: /^save$/i }, { res: 'android:id/button1' }]);
await sleep(4000);
const bst = await page.evaluate(async () => PDMNative.call('backup.status'));
check('backup saved via Android file picker and verified (status updated)', saved && bst.lastResult === 'success' && bst.lastSuccessAt && bst.lastSuccessAt !== before,
  JSON.stringify({ saved, result: bst.lastResult, file: bst.fileName, size: bst.sizeBytes, records: bst.records }));
const downloads = await sh('ls /sdcard/Download/ 2>/dev/null');
check('backup file exists on the phone storage', bst.fileName && downloads.includes(bst.fileName), downloads.split('\n').slice(-3).join(', '));
await page.evaluate(async () => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); await DB.del('documents', d.id); await loadAll(); });
check('invoice deleted after backup (to prove restore brings it back)', (await page.evaluate(() => State.documents.length)) === 0);
page.evaluate(() => Backup.pick()).catch(() => {});
await sleep(5000); await shot('10-android-open-screen');
let picked = await tapAny([{ text: bst.fileName }], 8000);
if (!picked) { await tapAny([{ desc: /show roots/i }], 3000); await sleep(1200); await tapAny([{ text: /^downloads$/i }], 3000); await sleep(1500); picked = await tapAny([{ text: bst.fileName }], 6000); }
check('backup file chosen in Android file picker', picked);
let restored = null;
if (picked) {
  await page.waitForSelector('#rs_ok', { timeout: 30000 }); await shot('11-restore-preview');
  check('restore preview shows the backup contents before changing anything', /Records in backup/.test(await page.textContent('#modal')));
  await page.check('#rs_ok');
  page.click('#rs_go').catch(() => {});
  await sleep(8000); await shot('12-restore-complete');
  await tapAny([{ text: /^ok$/i }], 15000);
  await sleep(3000);
  try { page = await launch(); } catch (e) { console.log('relaunch after restore', String(e)); }
  await login(page);
  restored = await page.evaluate(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return d ? { pays: d.payments.length, bal: docTotals(d).balance } : null; });
}
check('full restore on device brings the invoice and both payments back', restored && restored.pays === 2 && restored.bal === 10000, JSON.stringify(restored));

// ---- every screen renders on the phone ----
const errs = []; page.on('pageerror', e => errs.push(String(e)));
for (const v of await page.evaluate(() => MODULES.map(m => m.k))) { await page.evaluate(x => Nav.go(x), v); await sleep(250); }
await page.evaluate(() => Nav.go('sales')); await sleep(600); await shot('05-sales-screen');
await page.evaluate(() => Nav.go('expenses')); await sleep(600); await shot('06-expenses');
await page.evaluate(() => Nav.go('invoices')); await sleep(600); await shot('07-invoices');
check('all screens render on the phone without errors', errs.length === 0, errs.slice(0, 3).join(' | '));

// ---- crash check ----
const crash = await sh('logcat -d -b crash');
check('no app crash in logcat', !crash.includes(PKG), crash.slice(0, 300));

fs.writeFileSync(path.join(here, 'android-results.json'), JSON.stringify({ at: new Date().toISOString(), device: device.model(), passed: results.length - failed, failed, results }, null, 2));
console.log(`\n${results.length - failed}/${results.length} passed`);
try { if (browser) await browser.close(); } catch (e) {}
await device.close();
process.exit(failed ? 1 : 0);
