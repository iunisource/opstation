#!/usr/bin/env python3
"""Adds the Payment Advice share-link route to firebase.json (safe to run again).

  • hosting rewrite  /l/**  →  function paLink (us-central1), placed BEFORE the
    single-page-app catch-all so it wins.
  • functions source folder  "functions"  (Node 20).
Run from the folder that has firebase.json:  python3 tool/patch_firebase_json.py
"""
import json, sys, shutil

path = 'firebase.json'
try:
    cfg = json.load(open(path))
except FileNotFoundError:
    sys.exit('firebase.json not found — run this from the folder you deploy from.')

shutil.copy(path, path + '.bak')
rule = {"source": "/l/**", "function": {"functionId": "paLink", "region": "us-central1"}}

hostings = cfg['hosting'] if isinstance(cfg.get('hosting'), list) else [cfg.setdefault('hosting', {})]
for h in hostings:
    rw = h.setdefault('rewrites', [])
    rw[:] = [r for r in rw if r.get('source') != '/l/**']
    rw.insert(0, rule)

fx = cfg.get('functions')
entry = {"source": "functions", "codebase": "default", "runtime": "nodejs20"}
if fx is None:
    cfg['functions'] = [entry]
else:
    lst = fx if isinstance(fx, list) else [fx]
    if not any(f.get('source') == 'functions' for f in lst):
        lst.append(entry)
    cfg['functions'] = lst

json.dump(cfg, open(path, 'w'), indent=2)
print('firebase.json updated (backup: firebase.json.bak)')
print(json.dumps(cfg, indent=2))
