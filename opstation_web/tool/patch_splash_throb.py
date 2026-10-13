#!/usr/bin/env python3
"""Start-up splash: keep the Opstation logo still and make its SHADOW throb.

Adds a small, idempotent block just before </head> in web/index.html:
  • a soft brand-blue glow under the logo that grows and fades in a slow
    loop (1.6 s), so the splash reads as "loading" without the logo moving;
  • any animation / transform the logo already had is switched off, so the
    logo itself stays perfectly static;
  • the logo is found automatically: the image/logo next to the
    "Loading your workspace" text (or the first image on the splash).
Respects "reduce motion" (no throb, just a steady soft shadow).
Safe to run again: the block is replaced, never duplicated.
Run after (or without) tool/patch_splash_white.py — they don't conflict.
"""
import pathlib
import re
import sys

path = pathlib.Path(__file__).resolve().parent.parent / 'web' / 'index.html'
if not path.exists():
    sys.exit(f'Not found: {path}')

html = path.read_text(encoding='utf-8')
start, end = '<!-- opstation:splash-throb -->', '<!-- /opstation:splash-throb -->'
block = f"""{start}
<style>
  @keyframes opstThrob {{
    0%, 100% {{ filter: drop-shadow(0 4px 6px rgba(47, 111, 237, 0.10)); }}
    50%      {{ filter: drop-shadow(0 10px 28px rgba(47, 111, 237, 0.55)); }}
  }}
  .opst-throb {{
    animation: opstThrob 1.6s ease-in-out infinite !important;
    transform: none !important;
    will-change: filter;
  }}
  @media (prefers-reduced-motion: reduce) {{
    .opst-throb {{ animation: none !important; filter: drop-shadow(0 8px 20px rgba(47, 111, 237, 0.35)); }}
  }}
</style>
<script>
  (function () {{
    var tries = 0;
    function isLogo(el) {{
      if (!el || el.nodeType !== 1) return false;
      var t = el.tagName.toLowerCase();
      if (t === 'img' || t === 'svg' || t === 'picture' || t === 'canvas') return true;
      var bg = getComputedStyle(el).backgroundImage;
      return bg && bg !== 'none' && el.children.length === 0;
    }}
    function findLogo() {{
      var body = document.body;
      if (!body) return null;
      // 1) The splash container = the element holding "Loading your workspace".
      var all = body.getElementsByTagName('*');
      for (var i = 0; i < all.length; i++) {{
        var el = all[i];
        if (el.children.length === 0 && /loading your workspace/i.test(el.textContent || '')) {{
          var box = el.parentElement;
          for (var up = 0; box && box !== body && up < 4; up++, box = box.parentElement) {{
            var cands = box.querySelectorAll('img, svg, picture, canvas, [class*="logo" i], [id*="logo" i]');
            for (var j = 0; j < cands.length; j++) if (cands[j] !== el) return cands[j];
            // No image: the logo is a styled element (e.g. a coloured tile) —
            // take the first sibling block that isn't the loading text.
            for (var k = 0; k < box.children.length; k++) {{
              var c = box.children[k];
              if (!c.contains(el) && c.tagName.toLowerCase() !== 'script' && c.getBoundingClientRect().width > 0) return c;
            }}
          }}
        }}
      }}
      // 2) Anything named like a logo.
      var named = body.querySelector('[class*="logo" i], [id*="logo" i], img[alt*="opstation" i], img[src*="logo" i]');
      if (named) return named;
      // 3) First image on the page before Flutter mounts.
      if (!document.querySelector('flutter-view, flt-glass-pane')) {{
        var img = body.querySelector('img, svg');
        if (img && isLogo(img)) return img;
      }}
      return null;
    }}
    function apply() {{
      var logo = findLogo();
      if (logo) {{
        // Stop any animation on the logo's own wrapper too (logo must stay still).
        var p = logo.parentElement;
        if (p && p !== document.body) {{ p.style.animation = 'none'; p.style.transform = 'none'; }}
        logo.classList.add('opst-throb');
        return true;
      }}
      return false;
    }}
    function run() {{
      if (apply()) return;
      if (++tries < 40) setTimeout(run, 50); // splash may be injected a moment later
    }}
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run);
    else run();
  }})();
</script>
{end}"""

if start in html:
    html = re.sub(re.escape(start) + r'.*?' + re.escape(end), block, html, flags=re.S)
else:
    if '</head>' not in html:
        sys.exit('No </head> in index.html')
    html = html.replace('</head>', block + '\n</head>', 1)

path.write_text(html, encoding='utf-8')
print(f'Patched {path} — splash logo shadow now throbs.')
