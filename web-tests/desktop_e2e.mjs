// End-to-end tests of the shared HTML app running in DESKTOP mode (Chromium + IndexedDB).
// Run:  node web-tests/desktop_e2e.mjs        (needs the `playwright` npm package + Chromium)
// Covers: upgrade from the original v2 app's IndexedDB, persistence across reload,
// inch/feet calculations, payments as separate records, duplicate-submit protection,
// historical rates, atomic rollback, fixed expenses, backup v3 export + checksum,
// corrupted-backup rejection, full restore + verification, legacy v2 backup restore.
import { chromium } from 'playwright';
import fs from 'node:fs'; import path from 'node:path'; import os from 'node:os'; import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const NEW_APP = pathToFileURL(path.join(root, 'app/assets/www/index.html')).href;
const OLD_APP = pathToFileURL(path.join(root, 'desktop-original/PehlwaniaDoorMax-POS.html')).href;
const results = []; let failed = 0;
function check(name, cond, detail = '') { results.push({ name, ok: !!cond, detail }); if (!cond) failed++; console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); }

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pdm-'));
const exe = fs.existsSync('/opt/pw-browsers/chromium') ? undefined : undefined;
const ctx = await chromium.launchPersistentContext(path.join(tmp, 'profile'), { headless: true, acceptDownloads: true, args: ['--allow-file-access-from-files'] });
const page = await ctx.newPage();
const errors = []; page.on('pageerror', e => errors.push(String(e))); page.on('dialog', d => d.accept());

async function login() {
  await page.waitForSelector('#lg_user', { state: 'visible' });
  await page.waitForFunction(() => typeof State !== 'undefined' && State.users && State.users.length > 0, null, { timeout: 30000 });
  // the login form is cleared once at the end of start-up: retry if our typing was wiped
  for (let attempt = 0; attempt < 5; attempt++) {
    await page.fill('#lg_user', 'admin'); await page.fill('#lg_pass', 'admin'); await page.click('.login-btn');
    try { await page.waitForFunction(() => document.body.classList.contains('authed'), null, { timeout: 6000 }); return; } catch (e) { await page.waitForTimeout(500); }
  }
  throw new Error('login failed');
}
const ev = (fn, arg) => page.evaluate(fn, arg);

// ---------- 1. Original app (v2) creates real data ----------
await page.goto(OLD_APP); await login();
await ev(async () => {
  Views.sales(); Views.itemAdd(); Views.itemPick(0, 'Lassani door'); Views.itemSet(0, 'qty', '2'); Views.itemSet(0, 'rate', '15000');
  Views.setAdvance('10000'); await Views.saveDoc(false);
});
const oldDocs = await ev(async () => (await DB.getAll('documents')).length);
check('original v2 app: invoice created in its IndexedDB', oldDocs === 1);
const oldExport = await (async () => {
  const [dl] = await Promise.all([page.waitForEvent('download'), ev(() => Backup.export())]);
  const p = path.join(tmp, 'legacy-v2.json'); await dl.saveAs(p); return p;
})();
check('original v2 app: legacy backup file downloaded', fs.statSync(oldExport).size > 1000);

// ---------- 2. New app opens the same storage (schema upgrade 3 -> 4) ----------
await page.goto(NEW_APP); await login();
const up = await ev(async () => ({ docs: State.documents.length, fx: Array.isArray(State.fixedexpenses), grand: docTotals(State.documents[0]).grand, bal: docTotals(State.documents[0]).balance, prods: State.products.length }));
check('upgrade: existing invoice still present after opening new version', up.docs === 1, JSON.stringify(up));
check('upgrade: totals unchanged (30000 total, 20000 balance)', up.grand === 30000 && up.bal === 20000);
check('upgrade: new fixed-expenses store available', up.fx);
check('upgrade: spec products added without removing originals', up.prods >= 18 + 13 - 0 && (await ev(() => State.products.some(p => p.name === 'Lassani door') && State.products.some(p => p.name === '2x2 PVC Ceiling'))));

// ---------- 3. Inches calculation + atomic save ----------
await ev(async () => {
  Views.sales(); Views.itemAdd(); Views.itemPick(0, '2x2 PVC Ceiling');
  Views.itemSet(0, 'mu', 'in'); Views.itemSet(0, 'basis', 'sqft'); Views.itemSet(0, 'width', '36'); Views.itemSet(0, 'height', '84');
  Views.itemSet(0, 'qty', '2'); Views.itemSet(0, 'rate', '500');
  Views.itemAdd(); Views.itemPick(1, 'Uv almari'); Views.itemSet(1, 'mu', 'ft'); Views.itemSet(1, 'basis', 'sqft'); Views.itemSet(1, 'width', '4'); Views.itemSet(1, 'height', '7.5'); Views.itemSet(1, 'qty', '1'); Views.itemSet(1, 'rate', '1200');
  Views.setAdvance('5000'); Views._draft.customerName = 'Test Customer';
  await Promise.all([Views.saveDoc(false), Views.saveDoc(false)]); // double tap
});
const inv = await ev(async () => { const d = State.documents.find(x => x.customerName === 'Test Customer'); return { n: State.documents.filter(x => x.customerName === 'Test Customer').length, t: docTotals(d), items: d.items, pays: d.payments, no: d.no }; });
// 36x84 in = 21 sq ft x2 = 42 sq ft x 500 = 21000 ; 4x7.5 ft = 30 sq ft x 1200 = 36000
check('inch line: 36in×84in ÷144 ×2 qty ×500 = 21,000', Math.abs(inv.items[0] && (21 * 2 * 500)) === 21000 && inv.t.sub === 57000, `sub=${inv.t.sub}`);
check('feet line unchanged (4ft×7.5ft×1200 = 36,000)', inv.t.sub - 21000 === 36000);
check('double tap on Save creates only ONE invoice', inv.n === 1, `count=${inv.n}`);
check('items stored with stable IDs and unit', inv.items.every(i => typeof i.id === 'string' && i.id.length >= 20 && (i.mu === 'in' || i.mu === 'ft')));
check('advance stored as a payment record with its own ID', inv.pays.length === 1 && inv.pays[0].id && inv.pays[0].amount === 5000);

// ---------- 4. Payments: separate records, no duplicates ----------
await ev(async (no) => { const d = State.documents.find(x => x.no === no); Views.addPayment(d.id);
  document.querySelector('#p_amt').value = '12000'; await Promise.all([Views.savePayment(d.id), Views.savePayment(d.id)]); }, inv.no);
const afterPay = await ev(async (no) => { const d = State.documents.find(x => x.no === no); return { pays: d.payments.length, t: docTotals(d) }; }, inv.no);
check('second payment added once even when Save tapped twice', afterPay.pays === 2, `payments=${afterPay.pays}`);
check('balance = total − payments (57000 − 17000 = 40000)', afterPay.t.balance === 40000, `bal=${afterPay.t.balance}`);

// ---------- 5. Rate change does not alter old invoices ----------
await ev(async () => { const p = State.products.find(x => x.name === '2x2 PVC Ceiling'); Views.editProduct(p.id); document.querySelector('#f_price').value = '999'; await Views.saveProduct(p.id); });
const hist = await ev(async (no) => { const d = State.documents.find(x => x.no === no); const p = State.products.find(x => x.name === '2x2 PVC Ceiling'); return { rate: d.items[0].rate, grand: docTotals(d).grand, newRate: p.price, h: (p.rateHistory || []).length }; }, inv.no);
check('rate master: product rate updated to 999 with history entry', hist.newRate === 999 && hist.h === 1);
check('historical invoice keeps agreed rate 500 and total 57000', hist.rate === 500 && hist.grand === 57000);

// ---------- 6. Atomic rollback ----------
const rb = await ev(async () => { try { await DB.tx(async () => { await DB.put('expenses', { id: 'rollback-1', amount: 5, date: '2026-01-01' }); await DB.put('expenses', { amount: 1 }); }); return 'committed'; } catch (e) { DB.invalidate(); return (await DB.get('expenses', 'rollback-1')) ? 'partial' : 'rolled-back'; } });
check('failed multi-step save rolls back completely', rb === 'rolled-back', rb);

// ---------- 7. Expenses + fixed monthly ----------
await ev(async () => {
  Views.editExpense(); document.querySelector('#ex_amt').value = '1500'; document.querySelector('#ex_cat').value = 'Suzuki Transport / Fuel'; await Views.saveExpense('');
  Nav.go('expenses'); Views.editFixed(); document.querySelector('#fx_name').value = 'Shop rent'; document.querySelector('#fx_amt').value = '40000'; document.querySelector('#fx_start').value = new Date().toISOString().slice(0, 7); await Views.saveFixed('');
});
const fx = await ev(() => { const t = todayISO(); return { n: State.fixedexpenses.length, cost: fixedCostForRange(t.slice(0, 8) + '01', t, ''), costYear: fixedCostForRange(t.slice(0, 4) + '-01-01', t, ''), exp: State.expenses.length }; });
check('daily expense saved', fx.exp === 1);
check('fixed monthly expense counted once for this month', fx.n === 1 && fx.cost === 40000, JSON.stringify(fx));
await ev(() => Nav.go('reports')); const repTxt = await page.textContent('#rOut');
check('report shows fixed monthly expenses line', /Fixed monthly expenses/.test(repTxt));

// ---------- 8. Persistence across reload ----------
await page.reload(); await login();
const persisted = await ev(() => ({ d: State.documents.length, e: State.expenses.length, f: State.fixedexpenses.length }));
check('data survives app reload', persisted.d === 2 && persisted.e === 1 && persisted.f === 1, JSON.stringify(persisted));

// ---------- 9. Backup v3 ----------
const [dl] = await Promise.all([page.waitForEvent('download'), ev(() => Backup.export())]);
const bkPath = path.join(tmp, 'backup-v3.json'); await dl.saveAs(bkPath);
const bk = JSON.parse(fs.readFileSync(bkPath, 'utf8'));
const sha = crypto.createHash('sha256').update(bk.payload, 'utf8').digest('hex');
check('backup v3: format header present', bk.format === 'pehlwania-pos-backup' && bk.formatVersion === 3);
check('backup v3: SHA-256 checksum matches payload (independently computed)', sha === bk.payloadSha256);
const payload = JSON.parse(bk.payload);
check('backup v3: counts match contents', Object.entries(bk.counts).every(([k, v]) => (payload[k] || []).length === v));
check('backup v3: contains invoices, payments, fixed expenses, gallery, users', payload.documents.length === 2 && payload.fixedexpenses.length === 1 && payload.gallery.length === 24 && payload.users.length >= 1);
const st = await ev(() => Backup.getStatus());
check('backup status recorded (time, records, success)', st.lastResult === 'success' && st.records > 0 && st.lastSuccessAt);

// ---------- 10. Corrupted backup rejected ----------
const bad = { ...bk, payload: bk.payload.replace('Test Customer', 'Hacked Customer') }; fs.writeFileSync(path.join(tmp, 'bad.json'), JSON.stringify(bad));
await ev(() => Nav.go('sync'));
await page.setInputFiles('#restoreFile', path.join(tmp, 'bad.json'));
await page.waitForSelector('#modal .alert.err');
const hasBtn = await page.$('#rs_go');
check('corrupted backup: checksum error shown and no Restore button', !hasBtn && /Checksum mismatch/.test(await page.textContent('#modal')));
await ev(() => Modal.close());
const unsupported = { ...bk, formatVersion: 99 }; fs.writeFileSync(path.join(tmp, 'v99.json'), JSON.stringify(unsupported));
await page.setInputFiles('#restoreFile', path.join(tmp, 'v99.json')); await page.waitForSelector('#modal .alert.err');
check('unsupported future version rejected', /newer app version/.test(await page.textContent('#modal')) && !(await page.$('#rs_go')));
await ev(() => Modal.close());

// ---------- 11. Modify data then full restore ----------
await ev(async () => { const d = State.documents.find(x => x.customerName === 'Test Customer'); await DB.del('documents', d.id); await DB.put('expenses', { id: 'extra-after-backup', amount: 77, date: todayISO(), category: 'Misc' }); await loadAll(); });
check('before restore: invoice deleted, extra expense added', (await ev(() => State.documents.length)) === 1 && (await ev(() => State.expenses.length)) === 2);
await page.setInputFiles('#restoreFile', bkPath);
await page.waitForSelector('#rs_go'); await page.check('#rs_ok');
const [safety] = await Promise.all([page.waitForEvent('download'), Promise.all([page.waitForEvent('load'), page.click('#rs_go')])]);
check('safety backup of current data downloaded before restore', /SAFETY/.test(safety.suggestedFilename()));
await login();
const restored = await ev(() => { const d = State.documents.find(x => x.customerName === 'Test Customer'); return { docs: State.documents.length, exp: State.expenses.length, pays: d ? d.payments.length : -1, rate: d ? d.items[0].rate : -1, bal: d ? docTotals(d).balance : -1, fx: State.fixedexpenses.length }; });
check('restore: deleted invoice is back with both payments', restored.docs === 2 && restored.pays === 2, JSON.stringify(restored));
check('restore: balance and historical rate preserved', restored.bal === 40000 && restored.rate === 500);
check('restore: record added after backup is gone (replace-all policy)', restored.exp === 1);
check('restore: fixed expenses restored', restored.fx === 1);

// ---------- 12. Legacy v2 backup restore ----------
await ev(() => Nav.go('sync'));
await page.setInputFiles('#restoreFile', oldExport); await page.waitForSelector('#rs_go');
check('legacy v2 backup accepted (with "older format" note)', /Older backup format/.test(await page.textContent('#modal')));
await page.check('#rs_ok');
await Promise.all([page.waitForEvent('download'), Promise.all([page.waitForEvent('load'), page.click('#rs_go')])]);
await login();
const leg = await ev(() => ({ docs: State.documents.length, bal: docTotals(State.documents[0]).balance }));
check('legacy v2 restore: original invoice and balance back', leg.docs === 1 && leg.bal === 20000, JSON.stringify(leg));

// ---------- 12b. Material calculators ----------
await ev(() => Nav.go('calc'));
for (const k of ['pelling', 'uv', 'mediawall', 'padding', 'tiles', 'pvc10', 'design']) {
  await ev(x => Views.calc(x), k);
  await page.fill('#c_W_ft', '10');
  if (await page.$('#c_H_ft')) await page.fill('#c_H_ft', '10');
  if (await page.$('#c_L_ft')) await page.fill('#c_L_ft', '10');
  if (k === 'mediawall') await page.fill('#c_uv_ft', '4');
  await page.click('#calcGo');
  const res = await ev(() => Views._calcRes && { title: Views._calcRes.title, qty: Views._calcRes.materials.map(m => m.qty) });
  const expected = { pelling: [13], uv: [4], mediawall: [9, 2], padding: [2], tiles: [27], pvc10: [14], design: [] }[k];
  const shown = await page.$('#calcOut .calc-res');
  check(`calculator "${k}" shows a result on screen`, !!res && !!shown, JSON.stringify(res));
  if (expected.length) check(`calculator "${k}" quantities for 10 × 10 ft`, JSON.stringify(res.qty) === JSON.stringify(expected), JSON.stringify(res.qty));
}
// feet + inches input: 10 ft 6 in wall, 10" panels: 126/10 = 12.6 -> 13 strips of 10 ft -> 13 + 1 = 14
await ev(() => Views.calc('pelling')); await page.fill('#c_W_ft', '10'); await page.fill('#c_W_in', '6'); await page.fill('#c_H_ft', '10'); await page.click('#calcGo');
check('feet + inches converted before calculating (10 ft 6 in → 14 panels)', (await ev(() => Views._calcRes.materials[0].qty)) === 14);
await ev(() => Views.calc('tiles')); await page.fill('#c_W_ft', '-4'); await page.fill('#c_L_ft', '10'); await page.click('#calcGo');
check('negative measurement rejected with a message', /negative/.test(await page.textContent('#calcErr')) && !(await ev(() => Views._calcRes)));
await page.fill('#c_W_ft', ''); await page.click('#calcGo');
check('empty measurement rejected with a message', /greater than zero/.test(await page.textContent('#calcErr')));
await page.fill('#c_W_ft', '10'); await page.click('#calcGo');
const png = await ev(async () => { const d = await calcImage(Views._calcRes); const im = new Image(); im.src = d; await im.decode(); return { len: d.length, w: im.width, h: im.height, head: d.slice(0, 22) }; });
check('calculation image (PNG) generated for Save to Gallery', png.head === 'data:image/png;base64,' && png.w === 1080 && png.h > 900, JSON.stringify(png));
const [imgDl] = await Promise.all([page.waitForEvent('download'), ev(() => Views.calcSave())]);
check('desktop: Save downloads the PNG', /\.png$/.test(imgDl.suggestedFilename()), imgDl.suggestedFilename());
const share = await ev(() => calcShareText(Views._calcRes));
check('WhatsApp text has title, measurements and quantities', /2 × 2 PVC Ceiling Tiles/.test(share) && /Ceiling size/.test(share) && /\*27 tiles\*/.test(share), share.split('\n').slice(0, 4).join(' | '));
await ev(() => Views.calc('mediawall')); await page.fill('#c_W_ft', '10'); await page.fill('#c_H_ft', '10'); await page.fill('#c_uv_ft', '4'); await page.click('#calcGo');
await ev(() => Views.calcToQuote());
const q = await ev(() => ({ type: Views._draft.type, items: Views._draft.items.map(i => ({ d: i.desc, q: i.qty, b: i.basis, w: i.width, h: i.height, pid: !!i.productId })) }));
check('Add to quotation: panels + UV sheets as quotation lines linked to products', q.type === 'quote' && q.items.length === 2 && q.items[0].q === 9 && q.items[1].q === 2 && q.items.every(i => i.pid), JSON.stringify(q));
check('sq-ft priced panel line uses the real piece size (10 in × 114 in)', q.items[0].b === 'sqft' && q.items[0].w === 10 && q.items[0].h === 114);
await ev(() => Nav.go('dashboard'));

// ---------- 13. Every screen renders ----------
const views = await ev(() => MODULES.map(m => m.k));
for (const v of views) { await ev(v2 => Nav.go(v2), v); await page.waitForTimeout(120); }
await ev(() => Views.slideshow()); await ev(() => Views.closeLightbox());
check('all screens render without JavaScript errors', errors.length === 0, errors.slice(0, 3).join(' | '));

// phone layout smoke test
await page.setViewportSize({ width: 380, height: 800 }); await ev(() => Nav.go('dashboard'));
const overflow = await ev(() => document.documentElement.scrollWidth - window.innerWidth);
check('phone width (380px): no horizontal page overflow on dashboard', overflow <= 2, `overflow=${overflow}px`);
await page.screenshot({ path: path.join(root, 'web-tests', 'last-phone-dashboard.png') });

await ctx.close();
fs.writeFileSync(path.join(root, 'web-tests', 'last-results.json'), JSON.stringify({ at: new Date().toISOString(), passed: results.filter(r => r.ok).length, failed, results }, null, 2));
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
