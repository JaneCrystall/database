#!/usr/bin/env python3
"""Compare catalog-only JSON without exposing data or credentials."""
import argparse
import json
from pathlib import Path


def differences(expected,actual):
    result=[]
    for kind in ('relations','functions'):
        left={r['name']:r for r in expected[kind] or []}
        right={r['name']:r for r in actual[kind] or []}
        for name in sorted(left.keys()|right.keys()):
            if left.get(name)!=right.get(name):
                fields=sorted(f for f in set(left.get(name,{}))|set(right.get(name,{})) if left.get(name,{}).get(f)!=right.get(name,{}).get(f))
                result.append({'kind':kind,'name':name,'fields':fields})
    if expected['lang']!=actual['lang']:result.append({'kind':'enum','name':'lang'})
    if expected.get('enums')!=actual.get('enums'):result.append({'kind':'enums','name':'public'})
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--actual',type=Path,required=True);a=p.parse_args()
    expected=json.loads(Path(__file__).with_name('public_catalog.expected.json').read_text())
    actual=json.loads(a.actual.read_text());diff=differences(expected,actual)
    print(json.dumps({'catalog_parity':'failed' if diff else 'passed','relations':len(actual['relations'] or []),'functions':len(actual['functions'] or []),'differences':diff}))
    if diff:raise SystemExit(1)
if __name__=='__main__':main()
