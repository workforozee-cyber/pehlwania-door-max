#!/usr/bin/env python3
"""Builds the single-file desktop version from the shared app source.

app/assets/www/index.html + seed_gallery.js  ->  desktop/PehlwaniaDoorMax-POS.html
Usage: python3 tools/build_desktop.py [--check]
  --check  exit 1 if the committed desktop file is out of date (used by CI)
"""
import pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
www = root / 'app' / 'assets' / 'www'
html = (www / 'index.html').read_text(encoding='utf-8')
out = html
for js in ('seed_gallery.js', 'calc_engine.js'):
    tag = f'<script src="{js}"></script>'
    assert out.count(tag) == 1, f'{js} script tag not found'
    out = out.replace(tag, '<script>\n' + (www / js).read_text(encoding='utf-8') + '</script>')
target = root / 'desktop' / 'PehlwaniaDoorMax-POS.html'
if '--check' in sys.argv:
    cur = target.read_text(encoding='utf-8') if target.exists() else ''
    if cur != out:
        print('desktop/PehlwaniaDoorMax-POS.html is out of date: run python3 tools/build_desktop.py'); sys.exit(1)
    print('desktop build up to date'); sys.exit(0)
target.write_text(out, encoding='utf-8')
print(f'wrote {target} ({len(out):,} bytes)')
