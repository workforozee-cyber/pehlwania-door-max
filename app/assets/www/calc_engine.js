/* =========================================================
   Pehlwania Door Max — material calculators (pure functions)
   ---------------------------------------------------------
   All lengths are converted to FEET before any calculation.
   Quantities are counted from the physical layout (strips/rows of real
   panels and sheets, with offcut re-use along the length), never just
   "area ÷ piece area". The area-only figure is shown separately as
   "theoretical" for comparison. Final quantities are rounded UP.
   Used by index.html (Calculators screen) and by the automated tests.
   ========================================================= */
(function (root) {
  'use strict';
  const EPS = 1e-9;
  const STD_LENGTH_FT = 9.5;                 // panels, UV sheets, padding, 10" PVC
  const PANEL_WIDTHS_IN = [6, 10, 16];       // Normal / Hard pelling
  const UV_SHEET = { w: 4, l: 9.5 };         // feet
  const PADDING_W_IN = 10;
  const PVC10_W_IN = 10;
  const TILE_FT = 2;                         // 2 × 2 ft

  class CalcError extends Error {}

  /** feet + inches -> feet. Rejects empty, negative, non-numeric and zero total. */
  function toFeet(ft, inch, label) {
    const f = parseNum(ft, label + ' (feet)'), i = parseNum(inch, label + ' (inches)');
    const total = f + i / 12;
    if (!(total > 0)) throw new CalcError(`${label}: enter a size greater than zero.`);
    if (total > 1000) throw new CalcError(`${label}: ${fmtLen(total)} looks too large — please check.`);
    return total;
  }
  function parseNum(v, label) {
    if (v === '' || v == null) return 0;
    const n = Number(String(v).trim());
    if (!Number.isFinite(n)) throw new CalcError(`${label}: "${v}" is not a number.`);
    if (n < 0) throw new CalcError(`${label}: negative values are not allowed.`);
    return n;
  }
  function wastePct(v) {
    const n = parseNum(v, 'Wastage %');
    if (n > 50) throw new CalcError('Wastage %: use a value between 0 and 50.');
    return n;
  }
  const ceil = x => Math.ceil(x - EPS);          // 12.0000000001 -> 12
  const floor = x => Math.floor(x + EPS);        // 1.9999999999 -> 2
  const withWaste = (q, pct) => q === 0 ? 0 : ceil(q * (1 + pct / 100));
  const r2 = x => Math.round(x * 100) / 100;

  /** 10.5 -> "10 ft 6 in" */
  function fmtLen(ft) {
    let f = Math.floor(ft + EPS), i = Math.round((ft - f) * 12 * 100) / 100;
    if (i >= 12) { f += 1; i -= 12; }
    if (!f) return `${i} in`;
    return i ? `${f} ft ${i} in` : `${f} ft`;
  }
  const fmtArea = a => `${r2(a).toLocaleString('en-US', { maximumFractionDigits: 2 })} sq ft`;

  /**
   * n strips, each `run` ft long, cut from pieces of standard length L.
   * Short strips: one piece gives floor(L/run) strips.
   * Long strips: full pieces end to end + a remainder; remainders of equal
   * length are cut from shared pieces (floor(L/rem) remainders per piece).
   */
  function cutStrips(n, run, L) {
    if (n <= 0 || run <= 0) return { pieces: 0, perPiece: 0, fullPerStrip: 0, remainder: 0, joints: 0, offcut: 0 };
    if (run <= L + EPS) {
      const per = floor(L / run);
      const pieces = ceil(n / per);
      return { pieces, perPiece: per, fullPerStrip: 0, remainder: run, joints: 0, offcut: r2(pieces * L - n * run) };
    }
    const full = floor(run / L);
    const rem = run - full * L;
    if (rem < 1e-6) return { pieces: n * full, perPiece: 0, fullPerStrip: full, remainder: 0, joints: n * (full - 1), offcut: 0 };
    const per = floor(L / rem);
    const remPieces = ceil(n / per);
    const pieces = n * full + remPieces;
    return { pieces, perPiece: per, fullPerStrip: full, remainder: rem, joints: n * full, offcut: r2(pieces * L - n * run) };
  }

  /**
   * Cover a W × H area with strips of width `pw` (ft) and standard length L.
   * dir 'vertical': strips run along H (placed side by side across W).
   * dir 'horizontal': strips run along W (stacked across H).
   */
  function stripLayout(W, H, pw, L, dir) {
    const across = dir === 'horizontal' ? H : W;
    const run = dir === 'horizontal' ? W : H;
    const strips = ceil(across / pw);
    const cut = cutStrips(strips, run, L);
    return { dir, across, run, strips, ...cut, coveredAcross: r2(strips * pw), lastStripWidthIn: r2((across - (strips - 1) * pw) * 12) };
  }

  function stripSteps(name, lay, pwIn, L) {
    const s = [];
    s.push(`Strips needed: ${fmtLen(lay.across)} ÷ ${pwIn} in = ${r2(lay.across * 12 / pwIn)} → ${lay.strips} strips (rounded up; last strip ${lay.lastStripWidthIn} in wide)`);
    if (lay.fullPerStrip === 0) {
      s.push(`Each strip is ${fmtLen(lay.run)} long; one ${L} ft ${name} gives ${lay.perPiece} strip${lay.perPiece > 1 ? 's' : ''}`);
      s.push(`${name}s: ${lay.strips} ÷ ${lay.perPiece} = ${lay.pieces} (rounded up)`);
    } else {
      s.push(`Each strip is ${fmtLen(lay.run)} — longer than ${L} ft: ${lay.fullPerStrip} full ${name}${lay.fullPerStrip > 1 ? 's' : ''} + a ${fmtLen(lay.remainder)} piece (joint needed)`);
      if (lay.remainder > 0) s.push(`${fmtLen(lay.remainder)} pieces: ${lay.perPiece} cut from each ${name} → ${ceil(lay.strips / lay.perPiece)} extra ${name}s`);
      s.push(`${name}s: ${lay.strips} × ${lay.fullPerStrip} + ${lay.remainder > 0 ? ceil(lay.strips / lay.perPiece) : 0} = ${lay.pieces}`);
    }
    return s;
  }

  // ---------------------------------------------------------------- calculators
  /** 1. Normal / Hard pelling (wall panels 6/10/16 in × 9.5 ft) */
  function pelling({ type = 'Normal', widthIn = 10, W, H, dir = 'vertical', waste = 0 }) {
    if (!PANEL_WIDTHS_IN.includes(Number(widthIn))) throw new CalcError('Choose a panel width of 6, 10 or 16 inches.');
    const pw = widthIn / 12, L = STD_LENGTH_FT;
    const lay = stripLayout(W, H, pw, L, dir);
    const area = W * H, theoretical = ceil(area / (pw * L));
    const final = withWaste(lay.pieces, waste);
    const name = `${type} Pelling ${widthIn}"`;
    return {
      kind: 'pelling', title: `${type} Pelling — ${widthIn} inch panels`,
      inputs: [['Panel', `${type} Pelling, ${widthIn} in wide × ${L} ft long`], ['Wall size (W × H)', `${fmtLen(W)} × ${fmtLen(H)}`],
        ['Panels run', dir === 'horizontal' ? 'Horizontally (along the width)' : 'Vertically (along the height)'], ['Wastage allowance', `${waste}%`]],
      results: [['Total area', fmtArea(area)], ['Strips across the wall', `${lay.strips}`], ['Panels by layout', `${lay.pieces} pcs`],
        ['Panels to order', `${final} pcs`, true], ['Theoretical (area ÷ panel area)', `${theoretical} pcs — for comparison only`]],
      steps: [`Area: ${fmtLen(W)} × ${fmtLen(H)} = ${fmtArea(area)}`, `One panel: ${widthIn} in × ${L} ft = ${r2(pw * L)} sq ft`,
        ...stripSteps('panel', lay, widthIn, L), waste ? `Wastage ${waste}%: ${lay.pieces} × ${1 + waste / 100} = ${final} (rounded up)` : 'No wastage added',
        `Offcut left over: about ${fmtLen(lay.offcut)} of panel length`],
      materials: [{ key: `pelling-${type}-${widthIn}`, name, qty: final, unit: 'pcs', pieceWIn: widthIn, pieceLIn: L * 12 }],
      area,
    };
  }

  /** best of portrait / landscape sheet layout */
  function sheetLayout(W, H, sw, sl) {
    const portrait = stripLayout(W, H, sw, sl, 'vertical');   // 4 ft across width, 9.5 ft up
    const landscape = stripLayout(W, H, sw, sl, 'horizontal'); // 4 ft up, 9.5 ft across
    return landscape.pieces < portrait.pieces ? { best: landscape, other: portrait, orient: 'landscape' } : { best: portrait, other: landscape, orient: 'portrait' };
  }

  /** 2. UV sheet 4 × 9.5 ft */
  function uvSheet({ W, H, waste = 0 }) {
    const { best, other, orient } = sheetLayout(W, H, UV_SHEET.w, UV_SHEET.l);
    const area = W * H, sheetArea = UV_SHEET.w * UV_SHEET.l, theoretical = ceil(area / sheetArea);
    const final = withWaste(best.pieces, waste);
    return {
      kind: 'uv', title: 'UV Sheet (4 ft × 9.5 ft)',
      inputs: [['Sheet size', '4 ft × 9.5 ft (38 sq ft)'], ['Area size (W × H)', `${fmtLen(W)} × ${fmtLen(H)}`], ['Wastage allowance', `${waste}%`]],
      results: [['Total area', fmtArea(area)], ['Best layout', orient === 'portrait' ? 'Upright (4 ft across, 9.5 ft up)' : 'Sideways (9.5 ft across, 4 ft up)'],
        ['Sheets by layout', `${best.pieces} sheets`], ['Sheets to order', `${final} sheets`, true],
        ['Other layout would need', `${other.pieces} sheets`], ['Theoretical (area ÷ 38)', `${theoretical} sheets — for comparison only`]],
      steps: [`Area: ${fmtLen(W)} × ${fmtLen(H)} = ${fmtArea(area)}`,
        orient === 'portrait' ? 'Sheets placed upright: 4 ft wide strips across the width' : 'Sheets placed sideways: 4 ft high rows up the height',
        ...stripSteps('sheet', best, 48, UV_SHEET.l), waste ? `Wastage ${waste}%: ${best.pieces} → ${final}` : 'No wastage added'],
      materials: [{ key: 'uv', name: 'UV Sheet 4×9.5 ft', qty: final, unit: 'sheets', pieceWIn: 48, pieceLIn: 114 }],
      area,
    };
  }

  /** 3. Media wall: UV sheet section + pelling panels on the remaining width */
  function mediaWall({ W, H, type = 'Hard', widthIn = 10, uvW = 0, uvPos = 'center', dir = 'vertical', waste = 0 }) {
    if (!PANEL_WIDTHS_IN.includes(Number(widthIn))) throw new CalcError('Choose a panel width of 6, 10 or 16 inches.');
    if (uvW < 0) throw new CalcError('UV section width cannot be negative.');
    if (uvW > W + EPS) throw new CalcError(`UV section (${fmtLen(uvW)}) is wider than the wall (${fmtLen(W)}).`);
    const pw = widthIn / 12, L = STD_LENGTH_FT, area = W * H;
    const panelTotalW = Math.max(0, W - uvW);
    const zones = panelTotalW < 1e-6 ? [] : (uvW > 0 && uvPos === 'center') ? [panelTotalW / 2, panelTotalW / 2] : [panelTotalW];
    let panelPieces = 0, strips = 0; const steps = [`Wall: ${fmtLen(W)} × ${fmtLen(H)} = ${fmtArea(area)}`];
    // strips are counted per zone (each side is rounded up on its own); the strip
    // lengths are then cut together so short offcut pieces are shared between zones
    let run = 0;
    zones.forEach((zw, i) => {
      const lay = stripLayout(zw, H, pw, L, dir);
      strips += lay.strips; run = lay.run;
      steps.push(`Panel zone ${zones.length > 1 ? (i === 0 ? '(left)' : '(right)') : ''}: ${fmtLen(lay.across)} ÷ ${widthIn} in → ${lay.strips} strips of ${fmtLen(lay.run)}`);
    });
    if (zones.length && dir === 'horizontal' && zones.length > 1) {
      // horizontal rows in two side zones: each row is the zone width long
      panelPieces = 0; strips = 0; steps.length = 1;
      zones.forEach((zw, i) => { const lay = stripLayout(zw, H, pw, L, dir); panelPieces += lay.pieces; strips += lay.strips;
        steps.push(`Panel zone ${i === 0 ? '(left)' : '(right)'}: ${lay.strips} rows of ${fmtLen(lay.run)} → ${lay.pieces} panels`); });
    } else if (zones.length) {
      const c = cutStrips(strips, run, L); panelPieces = c.pieces;
      steps.push(run <= L + EPS ? `Each strip ${fmtLen(run)}: one ${L} ft panel gives ${c.perPiece} → ${strips} ÷ ${c.perPiece} = ${panelPieces} panels`
        : `Each strip ${fmtLen(run)}: ${c.fullPerStrip} full panel(s) + ${fmtLen(c.remainder)} piece (${c.perPiece} pieces per panel) → ${strips} × ${c.fullPerStrip} + ${ceil(strips / c.perPiece)} = ${panelPieces} panels`);
    }
    let uvPieces = 0, uvOrient = '';
    if (uvW > 1e-6) {
      const s = sheetLayout(uvW, H, UV_SHEET.w, UV_SHEET.l); uvPieces = s.best.pieces; uvOrient = s.orient;
      steps.push(`UV section: ${fmtLen(uvW)} × ${fmtLen(H)} = ${fmtArea(uvW * H)} → ${uvPieces} sheets (${uvOrient === 'portrait' ? 'upright' : 'sideways'})`);
    }
    const panelsFinal = withWaste(panelPieces, waste), uvFinal = withWaste(uvPieces, waste);
    if (waste) steps.push(`Wastage ${waste}%: panels ${panelPieces} → ${panelsFinal}, UV sheets ${uvPieces} → ${uvFinal}`);
    const name = `${type} Pelling ${widthIn}"`;
    return {
      kind: 'mediawall', title: 'Media Wall',
      inputs: [['Wall size (W × H)', `${fmtLen(W)} × ${fmtLen(H)}`], ['Pelling', `${type}, ${widthIn} in × ${L} ft`],
        ['UV sheet section', uvW > 0 ? `${fmtLen(uvW)} wide, ${uvPos === 'center' ? 'in the centre (panels both sides)' : 'on one side'}` : 'None (panels only)'],
        ['Wastage allowance', `${waste}%`]],
      results: [['Total wall area', fmtArea(area)], ['Panel area', fmtArea(panelTotalW * H)], ['UV sheet area', fmtArea(uvW * H)],
        [`${name} panels to order`, `${panelsFinal} pcs`, true], ['UV sheets to order (4×9.5 ft)', `${uvFinal} sheets`, true],
        ['Panel strips', `${strips}`]],
      steps,
      materials: [
        ...(panelsFinal ? [{ key: `pelling-${type}-${widthIn}`, name, qty: panelsFinal, unit: 'pcs', pieceWIn: widthIn, pieceLIn: 114 }] : []),
        ...(uvFinal ? [{ key: 'uv', name: 'UV Sheet 4×9.5 ft', qty: uvFinal, unit: 'sheets', pieceWIn: 48, pieceLIn: 114 }] : []),
      ],
      area,
    };
  }

  /** 4. Padding 10 in × 9.5 ft, along the chosen side(s) only */
  function padding({ W, H, sides = ['top'], rows = 1, waste = 0 }) {
    rows = Number(rows);
    if (!Number.isInteger(rows) || rows < 1 || rows > 20) throw new CalcError('Rows of padding: enter a whole number from 1 to 20.');
    if (!sides.length) throw new CalcError('Choose at least one side for the padding.');
    const L = STD_LENGTH_FT, pw = PADDING_W_IN / 12;
    const steps = [`Installation: ${fmtLen(W)} × ${fmtLen(H)} = ${fmtArea(W * H)}`, `Padding piece: ${PADDING_W_IN} in × ${L} ft; ${rows} row${rows > 1 ? 's' : ''} (${r2(rows * PADDING_W_IN)} in band)`];
    let pieces = 0, linear = 0, padArea = 0; const perSide = [];
    for (const side of sides) {
      const run = side === 'top' || side === 'bottom' ? W : H;
      const c = cutStrips(rows, run, L);
      pieces += c.pieces; linear += run * rows; padArea += run * rows * pw;
      perSide.push([`${side[0].toUpperCase() + side.slice(1)} side`, `${fmtLen(run)} × ${rows} row(s) → ${c.pieces} pcs`]);
      steps.push(`${side}: run ${fmtLen(run)}${run > L + EPS ? ` (longer than ${L} ft: ${c.fullPerStrip} full + ${fmtLen(c.remainder)} piece per row)` : ''} → ${c.pieces} pieces`);
    }
    const final = withWaste(pieces, waste);
    if (waste) steps.push(`Wastage ${waste}%: ${pieces} → ${final}`);
    return {
      kind: 'padding', title: 'Padding (10 inch × 9.5 ft)',
      inputs: [['Installation size (W × H)', `${fmtLen(W)} × ${fmtLen(H)}`], ['Padding on', sides.join(', ')], ['Rows', `${rows}`], ['Wastage allowance', `${waste}%`]],
      results: [['Installation area', fmtArea(W * H)], ...perSide, ['Total padding run', `${fmtLen(linear)}`], ['Padding area', fmtArea(padArea)],
        ['Padding pieces to order', `${final} pcs`, true]],
      steps,
      materials: [{ key: 'padding', name: 'Padding 10" × 9.5 ft', qty: final, unit: 'pcs', pieceWIn: 10, pieceLIn: 114 }],
      area: W * H,
    };
  }

  /** 5. 2 × 2 ft PVC ceiling tiles (grid layout) */
  function tiles2x2({ W, L, waste = 5 }) {
    const nx = ceil(W / TILE_FT), ny = ceil(L / TILE_FT);
    const fx = floor(W / TILE_FT), fy = floor(L / TILE_FT);
    const grid = nx * ny, full = fx * fy, cut = grid - full;
    const area = W * L, theoretical = ceil(area / 4), final = withWaste(grid, waste);
    return {
      kind: 'tiles', title: '2 × 2 PVC Ceiling Tiles',
      inputs: [['Ceiling size (W × L)', `${fmtLen(W)} × ${fmtLen(L)}`], ['Tile', '2 ft × 2 ft (4 sq ft)'], ['Wastage allowance', `${waste}%`]],
      results: [['Ceiling area', fmtArea(area)], ['Tiles across × along', `${nx} × ${ny}`], ['Full tiles', `${full}`], ['Cut tiles (edges)', `${cut}`],
        ['Tiles by layout', `${grid}`], ['Tiles to order', `${final} tiles`, true], ['Theoretical (area ÷ 4)', `${theoretical} — for comparison only`]],
      steps: [`Area: ${fmtLen(W)} × ${fmtLen(L)} = ${fmtArea(area)}`, `Across: ${fmtLen(W)} ÷ 2 ft = ${r2(W / 2)} → ${nx} tiles`,
        `Along: ${fmtLen(L)} ÷ 2 ft = ${r2(L / 2)} → ${ny} tiles`, `Grid: ${nx} × ${ny} = ${grid} positions (${full} full, ${cut} cut at the edges)`,
        waste ? `Wastage ${waste}% for cutting/breakage: ${grid} → ${final}` : 'No wastage added'],
      materials: [{ key: 'tile2x2', name: '2x2 PVC Ceiling', qty: final, unit: 'tiles', pieceWIn: 24, pieceLIn: 24 }],
      area,
    };
  }

  /** 6. 10-inch PVC ceiling panels (9.5 ft) — dir 'width': panels run along the width */
  function pvc10({ W, L, dir = 'auto', waste = 5 }) {
    const pw = PVC10_W_IN / 12, SL = STD_LENGTH_FT;
    // 'length': panels run along L (side by side across W) ; 'width': panels run along W
    const alongL = stripLayout(W, L, pw, SL, 'vertical');
    const alongW = stripLayout(W, L, pw, SL, 'horizontal');
    let chosen = dir === 'width' ? alongW : dir === 'length' ? alongL : (alongW.pieces < alongL.pieces ? alongW : alongL);
    const chosenName = chosen === alongW ? 'along the width' : 'along the length';
    const area = W * L, theoretical = ceil(area / (pw * SL)), final = withWaste(chosen.pieces, waste);
    return {
      kind: 'pvc10', title: '10 inch PVC Ceiling Panels',
      inputs: [['Ceiling size (W × L)', `${fmtLen(W)} × ${fmtLen(L)}`], ['Panel', `10 in × ${SL} ft`], ['Panels run', chosenName + (dir === 'auto' ? ' (fewest panels)' : '')], ['Wastage allowance', `${waste}%`]],
      results: [['Ceiling area', fmtArea(area)], ['Panel rows', `${chosen.strips} rows of ${fmtLen(chosen.run)}`], ['Is 9.5 ft enough per row?', chosen.run <= SL + EPS ? 'Yes — one length per row' : `No — ${chosen.fullPerStrip} full + ${fmtLen(chosen.remainder)} per row (joint)`],
        ['Panels by layout', `${chosen.pieces} pcs`], ['Panels to order', `${final} pcs`, true],
        [`If run ${chosen === alongW ? 'along the length' : 'along the width'}`, `${(chosen === alongW ? alongL : alongW).pieces} pcs`], ['Theoretical (area ÷ panel area)', `${theoretical} — for comparison only`]],
      steps: [`Area: ${fmtLen(W)} × ${fmtLen(L)} = ${fmtArea(area)}`, `Panels run ${chosenName}`, ...stripSteps('panel', chosen, PVC10_W_IN, SL),
        waste ? `Wastage ${waste}%: ${chosen.pieces} → ${final}` : 'No wastage added'],
      materials: [{ key: 'pvc10', name: '10" PVC Ceiling Panel', qty: final, unit: 'pcs', pieceWIn: 10, pieceLIn: 114 }],
      area,
    };
  }

  /** 7. PVC ceiling design: plain 10" panels / 2×2 tiles / border band + centre */
  function ceilingDesign({ W, L, design = 'border-tiles', borderRows = 1, waste = 5 }) {
    const designs = { 'plain10': 'Plain 10 inch panels', 'tiles': '2 × 2 tiles (grid)', 'border-tiles': '10 inch panel border + 2×2 tiles in centre', 'border-plain': '10 inch panel border + 10 inch panels in centre' };
    if (!designs[design]) throw new CalcError('Choose a ceiling design.');
    const area = W * L, perimeter = 2 * (W + L);
    const base = { kind: 'design', title: `PVC Ceiling — ${designs[design]}`, area };
    const inputs = [['Ceiling size (W × L)', `${fmtLen(W)} × ${fmtLen(L)}`], ['Design', designs[design]], ['Wastage allowance', `${waste}%`]];
    if (design === 'plain10') { const r = pvc10({ W, L, waste }); return { ...r, ...base, inputs, results: [['Perimeter (for edge trim)', fmtLen(perimeter)], ...r.results], steps: r.steps }; }
    if (design === 'tiles') { const r = tiles2x2({ W, L, waste }); return { ...r, ...base, inputs, results: [['Perimeter (for edge trim)', fmtLen(perimeter)], ...r.results], steps: r.steps }; }
    borderRows = Number(borderRows);
    if (!Number.isInteger(borderRows) || borderRows < 1 || borderRows > 10) throw new CalcError('Border rows: enter a whole number from 1 to 10.');
    const b = borderRows * PVC10_W_IN / 12;
    const cW = W - 2 * b, cL = L - 2 * b;
    if (cW <= 0.5 || cL <= 0.5) throw new CalcError(`The border (${r2(borderRows * 10)} in on each side) leaves no centre area. Use fewer border rows.`);
    const SL = STD_LENGTH_FT;
    // border: two long runs of full width W, two short runs between them (L − 2b); each `borderRows` rows
    const sideW = cutStrips(borderRows, W, SL), sideL = cutStrips(borderRows, cL, SL);
    const borderPieces = 2 * sideW.pieces + 2 * sideL.pieces;
    const borderArea = area - cW * cL;
    const centre = design === 'border-tiles' ? tiles2x2({ W: cW, L: cL, waste: 0 }) : pvc10({ W: cW, L: cL, waste: 0 });
    const centreQty = centre.materials[0].qty;
    const borderFinal = withWaste(borderPieces, waste), centreFinal = withWaste(centreQty, waste);
    const centreName = design === 'border-tiles' ? '2×2 tiles' : '10" panels';
    return {
      ...base, inputs: [...inputs, ['Border', `${borderRows} row(s) of 10 in panels = ${r2(borderRows * 10)} in band`]],
      results: [['Ceiling area', fmtArea(area)], ['Perimeter (for edge trim)', fmtLen(perimeter)], ['Border band area', fmtArea(borderArea)],
        ['Centre area', `${fmtLen(cW)} × ${fmtLen(cL)} = ${fmtArea(cW * cL)}`], ['Border panels to order (10" × 9.5 ft)', `${borderFinal} pcs`, true],
        [`Centre ${centreName} to order`, `${centreFinal} ${design === 'border-tiles' ? 'tiles' : 'pcs'}`, true]],
      steps: [`Area: ${fmtLen(W)} × ${fmtLen(L)} = ${fmtArea(area)}; perimeter ${fmtLen(perimeter)}`,
        `Border band: ${borderRows} × 10 in = ${r2(b * 12)} in on each side`,
        `Long sides: 2 × ${borderRows} row(s) of ${fmtLen(W)} → 2 × ${sideW.pieces} = ${2 * sideW.pieces} panels`,
        `Short sides (between): 2 × ${borderRows} row(s) of ${fmtLen(cL)} → 2 × ${sideL.pieces} = ${2 * sideL.pieces} panels`,
        `Centre: ${fmtLen(cW)} × ${fmtLen(cL)} → ${centreQty} ${centreName}`, ...centre.steps.slice(1).map(s => '   ' + s),
        waste ? `Wastage ${waste}%: border ${borderPieces} → ${borderFinal}, centre ${centreQty} → ${centreFinal}` : 'No wastage added'],
      materials: [{ key: 'pvc10', name: '10" PVC Ceiling Panel', qty: borderFinal + (design === 'border-plain' ? centreFinal : 0), unit: 'pcs', pieceWIn: 10, pieceLIn: 114 },
        ...(design === 'border-tiles' ? [{ key: 'tile2x2', name: '2x2 PVC Ceiling', qty: centreFinal, unit: 'tiles', pieceWIn: 24, pieceLIn: 24 }] : [])],
    };
  }

  const api = { CalcError, toFeet, wastePct, fmtLen, fmtArea, cutStrips, stripLayout, pelling, uvSheet, mediaWall, padding, tiles2x2, pvc10, ceilingDesign, STD_LENGTH_FT, PANEL_WIDTHS_IN };
  root.CalcEngine = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
