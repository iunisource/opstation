#!/usr/bin/env python3
"""Make the start-up splash ("Loading your workspace…") white.

Adds a small, idempotent block just before </head> in web/index.html:
  • html/body background → white (the grey came from the page background
    shown while Flutter downloads);
  • the splash container itself (whatever element holds the
    "Loading your workspace" text, and its parents up to <body>) → white.
Safe to run again: the block is replaced, never duplicated.
"""
import pathlib
import re
import sys

path = pathlib.Path(__file__).resolve().parent.parent / 'web' / 'index.html'
if not path.exists():
    sys.exit(f'Not found: {path}')

html = path.read_text(encoding='utf-8')
start, end = '<!-- opstation:splash-white -->', '<!-- /opstation:splash-white -->'
block = f"""{start}
<style>
  html, body {{ background: #ffffff !important; background-color: #ffffff !important; }}
</style>
<script>
  (function () {{
    function whiten() {{
      var all = document.body ? document.body.getElementsByTagName('*') : [];
      for (var i = 0; i < all.length; i++) {{
        var el = all[i];
        if (el.children.length === 0 && /loading your workspace/i.test(el.textContent || '')) {{
          var n = el;
          while (n && n !== document.body) {{
            var bg = getComputedStyle(n).backgroundColor;
            if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') n.style.backgroundColor = '#ffffff';
            n = n.parentElement;
          }}
        }}
      }}
    }}
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', whiten);
    else whiten();
  }})();
</script>
{end}"""

if start in html:
    html = re.sub(re.escape(start) + r'.*?' + re.escape(end), block, html, flags=re.S)
else:
    if '</head>' not in html:
        sys.exit('No </head> in index.html')
    html = html.replace('</head>', block + '\n</head>', 1)

# Also turn any grey theme-color / inline body background into white.
html = re.sub(r'(<body[^>]*style="[^"]*background(?:-color)?\s*:\s*)[^;"]+', r'\1#ffffff', html)
path.write_text(html, encoding='utf-8')
print(f'Patched {path}')
