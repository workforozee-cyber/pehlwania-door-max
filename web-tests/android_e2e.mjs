// Android emulator end-to-end test of the REAL app (CI build with
// --dart-define=PDM_WEBVIEW_DEBUG=true so the WebView can be inspected).
// Drives the shared screens through a minimal Chrome DevTools client
// (Node's built-in WebSocket/fetch), and Android's own screens (Save / Open /
// dialogs) through uiautomator. Verifies: native SQLite saves, inch maths,
// double-tap safety, payments, offline saving, print preview, backup through
// Android's Save screen, restore through Android's Open screen, data in the
// SQLite FILE after force-stop, and the UI after a real app restart.
import { execSync } from 'node:child_process';
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url';

const PKG = 'com.pehlwania.doormax';
const ACT = `${PKG}/com.pehlwania.pehlwania_pos.MainActivity`;
const here = path.dirname(fileURLToPath(import.meta.url));
const shots = path.join(here, 'android-shots'); fs.mkdirSync(shots, { recursive: true });
const results = []; let failed = 0;
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail: String(detail ?? '') }); if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const adb = (c, opts = {}) => execSync(`adb ${c}`, { maxBuffer: 64 << 20, ...opts });
const sh = c => { try { return adb(`shell ${JSON.stringify(c)}`).toString().trim(); } catch (e) { return ''; } };
const shot = name => { try { fs.writeFileSync(path.join(shots, name + '.png'), adb('exec-out screencap -p')); } catch (e) {} };

// ---------------------------------------------------------------- native UI taps
function uiNodes() {
  sh('uiautomator dump /sdcard/ui.xml >/dev/null 2>&1');
  const xml = sh('cat /sdcard/ui.xml');
  const nodes = [];
  for (const m of xml.matchAll(/<node [^>]*>/g)) {
    const a = {}; for (const kv of m[0].matchAll(/([\w-]+)="([^"]*)"/g)) a[kv[1]] = kv[2];
    const b = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/.exec(a.bounds || ''); if (!b) continue;
    nodes.push({ text: a.text || '', desc: a['content-desc'] || '', id: a['resource-id'] || '', x: (+b[1] + +b[3]) >> 1, y: (+b[2] + +b[4]) >> 1 });
  }
  return nodes;
}
async function uiTap(match, timeoutMs = 10000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const n = uiNodes().find(match);
    if (n) { sh(`input tap ${n.x} ${n.y}`); return true; }
    await sleep(1000);
  }
  return false;
}

// ---------------------------------------------------------------- DevTools client
let port = 9400, ws = null, msgId = 0; const pendingMsgs = new Map(); const pageErrors = [];
async function connect() {
  const pid = Number(sh(`pidof ${PKG}`));
  if (!pid) throw new Error('app process not running');
  const sock = `webview_devtools_remote_${pid}`;
  if (!sh('cat /proc/net/unix').includes(sock)) throw new Error('DevTools socket not open yet');
  const p = ++port; adb(`forward tcp:${p} localabstract:${sock}`);
  const list = await (await fetch(`http://127.0.0.1:${p}/json/list`)).json();
  const t = list.find(x => x.type === 'page' && /index\.html/.test(x.url));
  if (!t) throw new Error('page target not found yet');
  try { ws?.close(); } catch (e) {}
  ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('websocket error')); });
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pendingMsgs.has(m.id)) { const { res, rej } = pendingMsgs.get(m.id); pendingMsgs.delete(m.id); m.error ? rej(new Error(m.error.message)) : res(m.result); }
    else if (m.method === 'Runtime.exceptionThrown') pageErrors.push(m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text);
  };
  ws.onclose = () => { for (const { rej } of pendingMsgs.values()) rej(new Error('connection closed')); pendingMsgs.clear(); };
  await send('Runtime.enable');
  return pid;
}
function send(method, params = {}, timeout = 60000) {
  return new Promise((res, rej) => {
    const id = ++msgId; pendingMsgs.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => { if (pendingMsgs.has(id)) { pendingMsgs.delete(id); rej(new Error(`timeout ${method}`)); } }, timeout);
  });
}
/** Evaluate fn(arg) inside the page (awaits promises, returns JSON value). */
async function ev(fn, arg) {
  const r = await send('Runtime.evaluate', { expression: `(${fn.toString()})(${JSON.stringify(arg ?? null)})`, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
  return r.result.value;
}
/** Fire-and-forget (for calls that open Android screens and wait for the user). */
function evNoWait(fn, arg) { send('Runtime.evaluate', { expression: `(${fn.toString()})(${JSON.stringify(arg ?? null)})`, awaitPromise: false }).catch(() => {}); }
async function waitFor(fn, arg, timeoutMs = 60000) {
  const end = Date.now() + timeoutMs; let last;
  while (Date.now() < end) { try { if (await ev(fn, arg)) return true; } catch (e) { last = e; } await sleep(500); }
  throw new Error('waitFor timed out' + (last ? ': ' + last.message : ''));
}
async function launch() {
  sh(`am start -W -n ${ACT}`);
  for (let i = 0; i < 45; i++) {
    try {
      const pid = await connect();
      await waitFor(() => typeof State !== 'undefined' && State.users && State.users.length > 0, null, 60000);
      console.log(`app ready (pid ${pid})`); return pid;
    } catch (e) { if (i % 5 === 0) console.log('waiting for app:', e.message); await sleep(2000); }
  }
  throw new Error('app did not become ready');
}
async function login() {
  for (let i = 0; i < 5; i++) {
    await ev(() => { document.querySelector('#lg_user').value = 'admin'; document.querySelector('#lg_pass').value = 'admin'; Auth.login(); });
    try { await waitFor(() => document.body.classList.contains('authed'), null, 8000); return; } catch (e) { await sleep(800); }
  }
  throw new Error('login failed');
}
/** Copy the app's SQLite files from the device (debuggable build) and query them on the host. */
function dbQuery(q) {
  const dir = fs.mkdtempSync(path.join(here, 'db-'));
  for (const f of ['pehlwania_pos.db', 'pehlwania_pos.db-wal', 'pehlwania_pos.db-shm', 'pehlwania_pos.db-journal']) {
    try { fs.writeFileSync(path.join(dir, f), adb(`exec-out run-as ${PKG} cat databases/${f}`, { stdio: ['ignore', 'pipe', 'ignore'] })); } catch (e) {}
    try { if (fs.statSync(path.join(dir, f)).size === 0) fs.unlinkSync(path.join(dir, f)); } catch (e) {}
  }
  fs.writeFileSync(path.join(dir, 'q.json'), JSON.stringify(q));
  fs.writeFileSync(path.join(dir, 'q.py'), 'import sqlite3,json,sys\nc=sqlite3.connect(sys.argv[1])\nq=json.load(open(sys.argv[2]))\nprint(json.dumps({k:c.execute(v).fetchall() for k,v in q.items()}))\n');
  return JSON.parse(execSync(`python3 "${dir}/q.py" "${dir}/pehlwania_pos.db" "${dir}/q.json"`).toString());
}

// =================================================================== test
console.log('device', sh('getprop ro.product.model'), 'Android', sh('getprop ro.build.version.release'));
await launch(); await sleep(1000); shot('01-login');
check('app starts and shows login (native SQLite mode)', await ev(() => IS_NATIVE === true));
await login(); await sleep(800); shot('02-dashboard');

// ---- sale in inches, double tap, payment, expense ----
await ev(() => {
  Views.sales(); Views.itemAdd(); Views.itemPick(0, '2x2 PVC Ceiling');
  Views.itemSet(0, 'mu', 'in'); Views.itemSet(0, 'basis', 'sqft'); Views.itemSet(0, 'width', '36'); Views.itemSet(0, 'height', '84'); Views.itemSet(0, 'qty', '2'); Views.itemSet(0, 'rate', '500');
  Views.setAdvance('5000'); Views._draft.customerName = 'Emulator Customer';
});
await sleep(600); shot('03-new-sale-inches');
await ev(async () => { await Promise.all([Views.saveDoc(false), Views.saveDoc(false)]); });
const inv = await ev(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return { n: State.documents.filter(x => x.customerName === 'Emulator Customer').length, grand: docTotals(d).grand, bal: docTotals(d).balance, no: d.no, id: d.id }; });
check('invoice saved once (double tap guarded)', inv.n === 1, JSON.stringify(inv));
check('inch calculation on device: 36×84 in ×2 @500 = 21,000; balance 16,000', inv.grand === 21000 && inv.bal === 16000);
await ev(async id => { Views.addPayment(id); document.querySelector('#p_amt').value = '6000'; await Views.savePayment(id); }, inv.id);
await ev(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '1500'; document.querySelector('#ex_cat').value = 'Bijli Ka Bill'; await Views.saveExpense(''); });
check('records are read back from native SQLite through the bridge', (await ev(async () => (await PDMNative.call('db.getAll', { store: 'documents' })).length)) === 1);

// ---- offline ----
sh('cmd connectivity airplane-mode enable'); sh('svc wifi disable'); sh('svc data disable');
for (let i = 0; i < 20 && (await ev(() => PDMNative.call('sync.status'))).online; i++) await sleep(1000);
await ev(async () => { Views.editExpense(); document.querySelector('#ex_amt').value = '700'; document.querySelector('#ex_cat').value = 'Chaye / Khana'; await Views.saveExpense(''); });
check('saving works in airplane mode', (await ev(() => State.expenses.length)) === 2);
const st = await ev(() => PDMNative.call('sync.status'));
check('sync status: offline, Google not connected (no Google setup in CI)', st.online === false && (st.state === 'not_connected' || st.state === 'not_configured'), JSON.stringify({ online: st.online, state: st.state }));
check('changes are queued for Google Sheets while offline', st.pending > 0, `pending=${st.pending}`);
await ev(() => Nav.go('sync')); await sleep(1500); shot('04-backup-sync-offline');
sh('cmd connectivity airplane-mode disable'); sh('svc wifi enable'); sh('svc data enable'); await sleep(3000);

// ---- PDF bill: Android print preview ----
evNoWait(id => Print.doc(id), inv.id);
await sleep(8000); shot('05-print-preview');
const printUi = Number(sh('dumpsys activity activities | grep -i -c printspooler') || 0);
check('PDF bill generated and Android print preview opened', printUi > 0, `printspooler entries=${printUi}`);
for (let i = 0; i < 3 && Number(sh('dumpsys activity activities | grep -i -c printspooler') || 0) > 0; i++) { sh('input keyevent 4'); await sleep(2000); }

// ---- backup through Android's Save screen ----
await ev(() => Nav.go('sync')); await sleep(800);
const before = (await ev(() => PDMNative.call('backup.status'))).lastSuccessAt || null;
evNoWait(() => Backup.export());
await sleep(6000); shot('06-android-save-screen');
const saved = await uiTap(n => /^save$/i.test(n.text) || n.id === 'android:id/button1', 15000);
await sleep(6000);
const bst = await ev(() => PDMNative.call('backup.status'));
check('backup saved via Android file picker and verified', saved && bst.lastResult === 'success' && !!bst.lastSuccessAt && bst.lastSuccessAt !== before,
  JSON.stringify({ saved, result: bst.lastResult, file: bst.fileName, size: bst.sizeBytes, records: bst.records, error: bst.lastError }));
const downloads = sh('ls /sdcard/Download/');
check('backup file exists on phone storage', !!bst.fileName && downloads.includes(bst.fileName), downloads.split('\n').slice(-3).join(', '));

// ---- restore through Android's Open screen ----
await ev(async () => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); await DB.del('documents', d.id); await loadAll(); });
check('invoice deleted after the backup (restore must bring it back)', (await ev(() => State.documents.length)) === 0);
evNoWait(() => Backup.pick());
await sleep(6000); shot('07-android-open-screen');
const fname = bst.fileName || '__none__';
let picked = await uiTap(n => n.text === fname, 8000);
if (!picked) { await uiTap(n => /show roots/i.test(n.desc), 4000); await sleep(1200); await uiTap(n => /^downloads$/i.test(n.text), 4000); await sleep(1500); picked = await uiTap(n => n.text === fname, 8000); }
check('backup file chosen in Android file picker', picked);
let restored = null;
if (picked) {
  await waitFor(() => !!document.querySelector('#rs_ok'), null, 30000); shot('08-restore-preview');
  check('restore preview shows the backup contents before changing anything', await ev(() => /Records in backup/.test(document.querySelector('#modal').textContent)));
  evNoWait(() => { document.querySelector('#rs_ok').checked = true; document.querySelector('#rs_go').click(); });
  await sleep(8000); shot('09-restore-complete');
  // "Restore complete and verified" dialog (Flutter exposes its button as content-desc)
  const okTapped = await uiTap(n => /^ok$/i.test(n.text) || /^ok$/i.test(n.desc), 30000);
  if (!okTapped) sh('input keyevent 4'); // Back also closes the dialog
  console.log('restore dialog closed via', okTapped ? 'OK button' : 'Back key');
  await sleep(4000);
  await launch(); await login();
  restored = await ev(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return d ? { pays: d.payments.length, bal: docTotals(d).balance, exp: State.expenses.length } : null; });
}
check('full restore on device brings back the invoice, both payments and expenses', restored && restored.pays === 2 && restored.bal === 10000 && restored.exp === 2, JSON.stringify(restored));

// ---- every screen renders on the phone ----
const errsBefore = pageErrors.length;
for (const v of await ev(() => MODULES.map(m => m.k))) { await ev(x => Nav.go(x), v); await sleep(250); }
await ev(() => Nav.go('invoices')); await sleep(700); shot('10-invoices');
await ev(() => Nav.go('expenses')); await sleep(700); shot('11-expenses');
await ev(() => Nav.go('reports')); await sleep(700); shot('12-reports');
check('all screens render on the phone without JavaScript errors', pageErrors.length === errsBefore && pageErrors.length === 0, pageErrors.slice(0, 3).join(' | '));

// ---- force-stop: the data must be in the SQLite FILE ----
sh(`am force-stop ${PKG}`); await sleep(1500);
const q = {
  invoices: "SELECT no, grand_total FROM documents WHERE customer_name='Emulator Customer'",
  payments: "SELECT COUNT(*), SUM(amount) FROM payments p JOIN documents d ON d.id=p.document_id WHERE d.customer_name='Emulator Customer'",
  items: 'SELECT measure_unit, width, height, qty, rate, area_sqft, line_total FROM document_items',
  expenses: 'SELECT COUNT(*), SUM(amount) FROM expenses',
  audit: 'SELECT action FROM audit_log ORDER BY id',
  integrity: 'PRAGMA integrity_check',
  fk: 'PRAGMA foreign_key_check',
};
let db1 = null; try { db1 = dbQuery(q); } catch (e) { console.log('db read failed', String(e).slice(0, 300)); }
check('after force-stop: invoice is in the SQLite file with its total', db1 && db1.invoices.length === 1 && db1.invoices[0][1] === 21000, JSON.stringify(db1?.invoices));
check('after force-stop: both payments (11,000) stored as separate rows', db1 && db1.payments[0][0] === 2 && db1.payments[0][1] === 11000, JSON.stringify(db1?.payments));
check('after force-stop: item stored with inch unit, agreed rate 500, 21 sq ft per piece', db1 && db1.items.some(r => r[0] === 'in' && r[4] === 500 && Math.abs(r[5] - 21) < 1e-9 && r[6] === 21000), JSON.stringify(db1?.items));
check('after force-stop: expenses (incl. the offline one) stored', db1 && db1.expenses[0][0] === 2 && db1.expenses[0][1] === 2200, JSON.stringify(db1?.expenses));
check('database integrity and relationships OK', db1 && db1.integrity[0][0] === 'ok' && db1.fk.length === 0, JSON.stringify(db1?.integrity));
check('audit log recorded the restore', db1 && db1.audit.some(a => a[0] === 'restored'), JSON.stringify(db1?.audit.slice(-5)));

// ---- real restart: the app shows the same data ----
await launch(); await login(); await sleep(500); shot('13-after-restart');
const after = await ev(() => { const d = State.documents.find(x => x.customerName === 'Emulator Customer'); return d ? { pays: d.payments.length, bal: docTotals(d).balance, exp: State.expenses.length } : null; });
check('after force-stop + restart the app shows the invoice, payments and expenses', after && after.pays === 2 && after.bal === 10000 && after.exp === 2, JSON.stringify(after));

const crash = sh('logcat -d -b crash');
check('no app crash in logcat', !crash.includes(PKG), crash.slice(0, 300));

try { ws?.close(); } catch (e) {}
fs.writeFileSync(path.join(here, 'android-results.json'), JSON.stringify({ at: new Date().toISOString(), device: sh('getprop ro.product.model'), passed: results.length - failed, failed, results }, null, 2));
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
