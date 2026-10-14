#!/usr/bin/env python3
"""Compare catalog-only JSON without exposing data or credentials."""
import argparse
import json
from pathlib import Path


def differences(expected,actual):
    result=[]
    for kind in ('relations','functions'):
        key=lambda r: r['name'] if kind=='relations' else r['name']+'('+r['arguments']+')'
        left={key(r):r for r in expected[kind] or []}
        right={key(r):r for r in actual[kind] or []}
        for name in sorted(left.keys()|right.keys()):
            if left.get(name)!=right.get(name):
                fields=sorted(f for f in set(left.get(name,{}))|set(right.get(name,{})) if left.get(name,{}).get(f)!=right.get(name,{}).get(f))
                result.append({'kind':kind,'name':name,'fields':fields})
    if expected['lang']!=actual['lang']:result.append({'kind':'enum','name':'lang'})
    if expected.get('enums')!=actual.get('enums'):result.append({'kind':'enums','name':'public'})
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('--actual',type=Path,required=True);p.add_argument('--baseline-only',action='store_true');a=p.parse_args()
    # The pre-resource chain predates both resource migrations and the Jobs fix.
    # Keep its complete catalog independent from current migration expectations.
    fixture='pre_resource_catalog.expected.json' if a.baseline_only else 'public_catalog.expected.json'
    expected=json.loads(Path(__file__).with_name(fixture).read_text())
    if not a.baseline_only:
        additions=json.loads(Path(__file__).with_name('resource_catalog.expected.json').read_text())
        for kind in ('relations','functions'):
            original={r['name'] for r in expected[kind]}
            if any(r['name'] in original for r in additions[kind]):
                raise SystemExit('Additive catalog must not replace legacy objects')
            expected[kind] += additions[kind]
    actual=json.loads(a.actual.read_text());diff=differences(expected,actual)
    print(json.dumps({'catalog_parity':'failed' if diff else 'passed','relations':len(actual['relations'] or []),'functions':len(actual['functions'] or []),'differences':diff}))
    if diff:raise SystemExit(1)
if __name__=='__main__':main()
