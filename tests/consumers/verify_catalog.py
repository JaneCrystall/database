#!/usr/bin/env python3
"""Compare target schema metadata with the production schema-only contract."""
import argparse,json,sys
from pathlib import Path
import psycopg2
from runtime import load_private,validate_target
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--target',type=Path,required=True);a=p.parse_args()
t=load_private(a.target);validate_target(t)
with psycopg2.connect(t['db_url'],connect_timeout=15) as connection:
 connection.set_session(readonly=True)
 with connection.cursor() as cursor:
  cursor.execute((ROOT/'tests/schema/public_catalog.sql').read_text())
  actual=cursor.fetchone()[0]
expected=json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())
if actual!=expected:
 differences=[]
 for key in ('relations','functions'):
  left={r['name']:r for r in expected[key]};right={r['name']:r for r in actual[key] or []}
  for name in sorted(left.keys()|right.keys()):
   if left.get(name)!=right.get(name):
    fields=[f for f in set(left.get(name,{}))|set(right.get(name,{})) if left.get(name,{}).get(f)!=right.get(name,{}).get(f)]
    differences.append({'kind':key,'name':name,'fields':fields})
 if expected['lang']!=actual['lang']:differences.append({'kind':'enum','name':'lang'})
 if expected.get('enums')!=actual.get('enums'):differences.append({'kind':'enums','name':'public'})
 print(json.dumps({'catalog_parity':'failed','differences':differences}));raise SystemExit(1)
print(json.dumps({'catalog_parity':'passed','relations':len(actual['relations']),'functions':len(actual['functions']),'lang_labels':len(actual['lang']),'target_mode':t['mode']}))
