#!/usr/bin/env python3
"""Real Auth/PostgREST negative cases on an explicitly verified disposable Preview."""
import argparse
import json
from pathlib import Path
import sys
import traceback
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from unstructure_worker_flow import preview_target

ROOT = Path(__file__).resolve().parents[2]


def run(path, expected_ref):
    target = preview_target(path, expected_ref)
    actor = target['user']
    public = target['publishable_key']

    def request(route, *, token=None, body=None, method=None, profile=None):
        headers = {'apikey': public, 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        if profile:
            headers['Accept-Profile'] = profile
        req = Request(target['api_url'] + route, headers=headers, method=method,
                      data=json.dumps(body).encode() if body is not None else None)
        try:
            with urlopen(req, timeout=30) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else None
        except HTTPError as error:
            return error.code, json.loads(error.read())

    code, login = request('/auth/v1/token?grant_type=password',
                          body={'email': actor['email'], 'password': actor['password']})
    assert code == 200 and login.get('user', {}).get('id') == actor['id'], 'Synthetic sign-in failed'
    token = login['access_token']
    catalog = json.loads((ROOT/'tests/schema/public_catalog.expected.json').read_text())
    policy = json.loads((ROOT/'tests/schema/legacy_acl_policy.json').read_text())
    restricted = {s.split('(')[0].removeprefix('public.') for s in policy['restricted_functions']}
    functions = [f for f in catalog['functions'] if f['name'] in restricted and f['returns'] != 'trigger']
    assert functions, 'Restricted RPC selection is empty'
    checks = []
    for function in functions:
        args = {arg.split(' ', 1)[0]: None for arg in function['arguments'].split(', ') if arg}
        for role, jwt, expected in [('anon', None, 401), ('authenticated', token, 403)]:
            code, data = request('/rest/v1/rpc/' + function['name'], token=jwt, body=args)
            assert code == expected and data.get('code') == '42501', 'Restricted RPC admission changed'
            checks.append({'rpc': function['name'], 'role': role, 'status': code, 'code': '42501'})
    for role, jwt, expected in [('anon', None, 401), ('authenticated', token, 403)]:
        for method in ('POST', 'PATCH', 'DELETE'):
            body = {'name': 'synthetic denied'} if method != 'DELETE' else None
            code, data = request('/rest/v1/edu_meta?id=eq.' + target['fixtures']['resource_ids']['education'],
                                 token=jwt, body=body, method=method)
            assert code == expected and data.get('code') == '42501', 'Ordinary table write admitted'
    code, rows = request('/rest/v1/journals?id=eq.' + target['fixtures']['journal_id'] + '&select=id', token=token)
    assert code == 200 and rows == [{'id': target['fixtures']['journal_id']}], 'Authenticated journal SELECT failed'
    code, rows = request('/rest/v1/journals?id=eq.' + target['fixtures']['journal_id'] + '&select=id')
    assert code == 200 and rows == [], 'Anonymous journal RLS changed'
    code, data = request('/rest/v1/kb_resource_entries?select=id&limit=0', token=token, profile='private')
    assert code == 406 and data.get('code') == 'PGRST106', 'Private schema exposed'
    return {'schema_version': 1, 'passed': True, 'mode': 'preview', 'run_id': target['run_id'],
            'restricted_rpc_checks': checks, 'table_write_denials': 6,
            'journal_authenticated_read': True, 'journal_anon_empty': True,
            'private_profile_rejected': True, 'production_qualified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--preview-ref', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.target, args.preview_ref), indent=2))
        return 0
    except Exception as error:
        # Never expose authentication responses, credentials, SQL text or DSNs.
        print(json.dumps({'passed': False, 'error_type': type(error).__name__,
                          'locations': [(Path(f.filename).name, f.lineno)
                                        for f in traceback.extract_tb(error.__traceback__)]}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
