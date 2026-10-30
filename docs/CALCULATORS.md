# Material calculators — formulas (v3.1.0)

Menu → **📐 Calculators**. Works on Android and on the desktop version.
Code: `app/assets/www/calc_engine.js` (pure functions) · tests: `web-tests/calc_engine_test.mjs` (40 hand-checked cases).

## Common rules
- Every size is entered as **feet + inches** (decimals allowed, e.g. `7.25` ft or `6.5` in) and converted to feet:
  `feet = ft + in ÷ 12`. Empty, zero, negative or non-numeric sizes are rejected with a message (no division by zero).
- Standard lengths: pelling panels, UV sheets, padding and 10" PVC panels are **9.5 ft** long.
- **Quantities come from the physical layout**, not from area alone:
  1. **Strips** across the wall/ceiling = `⌈ width ÷ piece width ⌉` (the last strip is cut narrower).
  2. Each strip is as long as the other side (the **run**).
     - run ≤ 9.5 ft → one piece gives `⌊9.5 ÷ run⌋` strips → pieces = `⌈strips ÷ that⌉`.
     - run > 9.5 ft → each strip needs `⌊run ÷ 9.5⌋` full pieces **plus a remainder** piece (a joint).
       Remainders of the same length are cut from shared pieces: `⌊9.5 ÷ remainder⌋` per piece.
       pieces = `strips × full + ⌈strips ÷ remainders-per-piece⌉`.
  3. **Wastage %** (0–50, configurable per calculation) is added last: `⌈pieces × (1 + %/100)⌉`.
- The **theoretical** figure `⌈area ÷ piece area⌉` is shown separately for comparison only (it is usually too low
  because it ignores rounding to whole strips and the 9.5 ft length).
- All final quantities are rounded **up** to whole pieces.

## 1. Normal / Hard Pelling
Panel widths 6, 10 or 16 in × 9.5 ft. Panels run vertically (default) or horizontally.
Example: 10 × 10 ft wall, 10" panels → 120 ÷ 10 = **12 strips** of 10 ft; 10 ft > 9.5 ft → 12 full + 12 × 6 in pieces
(19 per panel → 1 panel) = **13 panels** (5% wastage → 14). Area only would say 12.6.

## 2. UV Sheet (4 × 9.5 ft)
Both layouts are calculated — upright (4 ft strips across the width) and sideways (4 ft rows up the height) — and the one
needing fewer sheets is used. Example 10 × 10 ft: 3 strips of 10 ft → 3 + 1 = **4 sheets** (area only: 2.6 → 3, which would not cover).

## 3. Media Wall
Wall W × H with an optional **UV sheet section** (width, in the centre or one side) and Normal/Hard pelling on the rest.
- Panel zones: centre UV → two side zones of `(W − UV width) ÷ 2`; each zone's strips are rounded up separately; offcut
  pieces are shared. UV section uses the UV sheet rule above.
- Example 10 × 10 ft, 4 ft UV centre, Hard 10": zones 3 ft + 3 ft → 4 + 4 = 8 strips of 10 ft → **9 panels**; UV 4 × 10 ft → **2 sheets**.
- UV width 0 = panels only; UV width = wall width = UV sheets only.

## 4. Padding (10 in × 9.5 ft)
Only the **sides you tick** (top, bottom, left, right) — never all four automatically. Top/bottom run = width,
left/right run = height. `Rows` = how many 10-inch bands on that side. Each side: strip rule above with strips = rows.
Example: top of a 10 ft wide wall, 1 row → 1 full + 6 in piece = **2 pieces**.

## 5. 2 × 2 PVC Ceiling Tiles
Tiles across = `⌈W ÷ 2⌉`, along = `⌈L ÷ 2⌉`, tiles = across × along (full tiles and edge cut tiles listed).
Default wastage 5%. Example 10 × 10 ft → 5 × 5 = 25 → **27** with 5%. 11 × 9 ft → 6 × 5 = 30 (20 full + 10 cut).

## 6. 10" PVC Ceiling Panels (9.5 ft)
Strip rule with 10" width. Direction: along the length, along the width, or **automatic** (fewer panels).
The result says whether 9.5 ft is enough for each row or a joint is needed.
Example 12 × 10 ft → 16 panels either way.

## 7. PVC Ceiling Design
Designs: plain 10" panels · 2×2 tiles · **10" panel border + 2×2 tiles centre** · 10" panel border + 10" panels centre.
Border band = rows × 10 in on every side. Long sides: rows of full width W; short sides: rows of `L − 2 × band`
(between the long sides). Centre = `(W − 2·band) × (L − 2·band)` calculated with the tile or panel rule.
Perimeter is shown for edge trim/angle.
Example 12 × 10 ft, 1 border row: long sides 2 × 2 = 4 panels, short sides 2 × 1 = 2 → **6 border panels**;
centre 10 ft 4 in × 8 ft 4 in → 6 × 5 = **30 tiles**.

## Save, share, quotation
- **Save to Gallery** (Android): a PNG card (shop name, project, measurements, results, calculation steps, branch phone)
  is written with MediaStore to **Pictures/Pehlwania POS** — visible in the Gallery. Android 10+ needs no permission;
  Android 7–9 asks for storage permission once. Desktop: the PNG is downloaded.
- **Share on WhatsApp**: text + the same image go straight to WhatsApp (or WhatsApp Business). If a customer number is
  entered, WhatsApp is asked to open that chat (works on most versions). Without WhatsApp, the normal Android share
  sheet opens. Desktop: opens WhatsApp Web with the text.
- **Add to new quotation**: creates quotation lines linked to the products (6/10/16" Normal/Hard paneling, UV Sheet,
  Padding, 10" PVC panel, 2×2 PVC). Products priced per sq ft are priced by each piece's real size
  (e.g. 10 in × 114 in). Rates come from Products — check them before saving.

## Assumptions
- Offcuts are re-used only along the length (same-size remainders); cut strips across the width are not joined.
- Tiles: each edge position uses one tile (offcuts of PVC tiles are usually not reusable).
- Panel/sheet thickness, frame, glue and trim materials are not calculated (perimeter is shown for trims).
