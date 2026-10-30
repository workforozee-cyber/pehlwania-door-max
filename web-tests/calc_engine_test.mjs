// Unit tests for the material calculators (expected values worked out by hand).
// Run: node web-tests/calc_engine_test.mjs
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const C = require('../app/assets/www/calc_engine.js');

let failed = 0; const results = [];
function eq(name, got, want) { const ok = JSON.stringify(got) === JSON.stringify(want); results.push({ name, ok }); if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `  — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`); }
function throws(name, fn, re) { let msg = ''; try { fn(); } catch (e) { msg = e.message; } const ok = re.test(msg); results.push({ name, ok }); if (!ok) failed++; console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : ' — message: ' + msg}`); }
const qty = r => r.materials.map(m => m.qty);

// ---- conversions & validation
eq('10 ft 6 in = 10.5 ft', C.toFeet('10', '6', 'W'), 10.5);
eq('decimal feet accepted (7.25 ft)', C.toFeet('7.25', '', 'W'), 7.25);
eq('inches only (114 in = 9.5 ft)', C.toFeet('', '114', 'H'), 9.5);
throws('empty size rejected', () => C.toFeet('', '', 'Width'), /greater than zero/);
throws('negative rejected', () => C.toFeet('-3', '0', 'Width'), /negative/);
throws('text rejected', () => C.toFeet('abc', '0', 'Width'), /not a number/);
throws('zero rejected', () => C.toFeet('0', '0', 'Height'), /greater than zero/);
throws('wastage above 50% rejected', () => C.wastePct('80'), /between 0 and 50/);
eq('format 10.5 ft', C.fmtLen(10.5), '10 ft 6 in');

// ---- 1. pelling (10 x 10 ft wall, 10" panels, vertical)
let r = C.pelling({ type: 'Hard', widthIn: 10, W: 10, H: 10 });
// 120 in / 10 in = 12 strips (exact: no float overshoot to 13); 10 ft > 9.5 ft: 12 full + 0.5 ft pieces (19 per panel) = 12 + 1 = 13
eq('pelling 10x10 ft, 10": 12 strips', r.results.find(x => x[0] === 'Strips across the wall')[1], '12');
eq('pelling 10x10 ft, 10": 13 panels', qty(r), [13]);
eq('pelling 10x10 ft with 5% wastage: 14', qty(C.pelling({ widthIn: 10, W: 10, H: 10, waste: 5 })), [14]);
eq('pelling 10 ft x 9 ft (fits 9.5 ft): 12 panels', qty(C.pelling({ widthIn: 10, W: 10, H: 9 })), [12]);
eq('pelling 6" on 8 x 4 ft: 16 strips, 2 per panel = 8', qty(C.pelling({ widthIn: 6, W: 8, H: 4 })), [8]);
eq('pelling 16" on 10 ft wide x 9 ft: 7.5 -> 8 panels', qty(C.pelling({ widthIn: 16, W: 10, H: 9 })), [8]);
eq('pelling 10" on 20 ft high wall, 5 ft wide: 6 strips × 2 full + 1 ft pieces (9/panel) = 13', qty(C.pelling({ widthIn: 10, W: 5, H: 20 })), [13]);
eq('pelling horizontal 10 ft wide x 5 ft: 6 rows of 10 ft = 6 + 1 = 7', qty(C.pelling({ widthIn: 10, W: 10, H: 5, dir: 'horizontal' })), [7]);
throws('pelling width must be 6/10/16', () => C.pelling({ widthIn: 12, W: 5, H: 5 }), /6, 10 or 16/);

// ---- 2. UV sheet
r = C.uvSheet({ W: 10, H: 10 });
eq('UV 10x10: 4 sheets by layout (area alone would say 3)', qty(r), [4]);
eq('UV 10x10 theoretical shown separately', r.results.find(x => x[0].startsWith('Theoretical'))[1].startsWith('3'), true);
eq('UV 8 ft wide x 9 ft high: 2 upright sheets', qty(C.uvSheet({ W: 8, H: 9 })), [2]);
eq('UV 19 ft wide x 4 ft high: 2 sideways sheets', qty(C.uvSheet({ W: 19, H: 4 })), [2]);

// ---- 3. media wall 10 x 10, hard 10", UV 4 ft centre
r = C.mediaWall({ W: 10, H: 10, type: 'Hard', widthIn: 10, uvW: 4 });
// panels: two 3 ft zones -> 4 + 4 = 8 strips of 10 ft -> 8 full + 8 half-foot pieces from 1 panel = 9 ; UV 4 x 10 -> 2 sheets
eq('media wall 10x10 with 4 ft UV centre: 9 panels + 2 UV sheets', qty(r), [9, 2]);
eq('media wall all panels (no UV) 10x10: 13 panels', qty(C.mediaWall({ W: 10, H: 10, widthIn: 10, uvW: 0 })), [13]);
eq('media wall all UV (uv = wall width) 8x9: 2 sheets only', qty(C.mediaWall({ W: 8, H: 9, widthIn: 10, uvW: 8 })), [2]);
throws('media wall: UV wider than wall rejected', () => C.mediaWall({ W: 8, H: 9, uvW: 9 }), /wider than the wall/);

// ---- 4. padding 10" x 9.5 ft
eq('padding top only on 10 ft wide: 1 full + 0.5 ft piece = 2', qty(C.padding({ W: 10, H: 8, sides: ['top'] })), [2]);
eq('padding top + left (10 ft + 8 ft): 2 + 1 = 3', qty(C.padding({ W: 10, H: 8, sides: ['top', 'left'] })), [3]);
eq('padding top, 2 rows of 10 ft: 2 full + both 0.5 ft pieces from 1 = 3', qty(C.padding({ W: 10, H: 8, sides: ['top'], rows: 2 })), [3]);
eq('padding one side of 9 ft: 1 piece', qty(C.padding({ W: 9, H: 8, sides: ['top'] })), [1]);
throws('padding needs a side', () => C.padding({ W: 9, H: 8, sides: [] }), /at least one side/);

// ---- 5. 2x2 tiles
eq('tiles 10x10 ft: 25, +5% = 27', qty(C.tiles2x2({ W: 10, L: 10, waste: 5 })), [27]);
eq('tiles 10x10 ft no wastage: 25', qty(C.tiles2x2({ W: 10, L: 10, waste: 0 })), [25]);
r = C.tiles2x2({ W: 11, L: 9, waste: 0 });
eq('tiles 11x9: 6 x 5 = 30 (20 full + 10 cut)', [qty(r)[0], r.results.find(x => x[0] === 'Full tiles')[1], r.results.find(x => x[0].startsWith('Cut'))[1]], [30, '20', '10']);

// ---- 6. 10" PVC ceiling
eq('PVC 10" 12 x 10 ft: 16 panels', qty(C.pvc10({ W: 12, L: 10, waste: 0 })), [16]);
eq('PVC 10" 10 x 9 ft along length (9 ft runs): 12 panels', qty(C.pvc10({ W: 10, L: 9, dir: 'length', waste: 0 })), [12]);
eq('PVC 10" auto picks fewer: 9 x 20 ft -> along length 11 strips x (2 full + 1 ft) = 22 + 2 = 24 vs along width 24 strips of 9 ft = 24', qty(C.pvc10({ W: 9, L: 20, waste: 0 })), [24]);

// ---- 7. ceiling design
r = C.ceilingDesign({ W: 12, L: 10, design: 'border-tiles', borderRows: 1, waste: 0 });
// border: 2 x (12 ft: 1 full + 2.5 ft) = 2 x 2 = 4 ; 2 x (8 ft 4 in) = 2 ; centre 10'4" x 8'4" -> 6 x 5 = 30 tiles
eq('design border + tiles 12x10: 6 border panels + 30 tiles', qty(r), [6, 30]);
eq('design plain 10" = pvc10', qty(C.ceilingDesign({ W: 12, L: 10, design: 'plain10', waste: 0 })), [16]);
throws('design: border too wide rejected', () => C.ceilingDesign({ W: 2, L: 2, design: 'border-tiles', borderRows: 2 }), /no centre area/);

console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
