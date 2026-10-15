#!/usr/bin/env python3
"""Compare target schema metadata with the production schema-only contract."""
import argparse,json,sys,subprocess,tempfile
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
# Use the same complete current-chain comparator as the local database gate.
# It combines the legacy and resource fixtures and rejects overlap/body/ACL drift.
with tempfile.TemporaryDirectory(prefix='s9-catalog-') as directory:
 actual_path=Path(directory)/'actual.json'
 actual_path.write_text(json.dumps(actual))
 result=subprocess.run([sys.executable,str(ROOT/'tests/schema/check_catalog.py'),
                        '--actual',str(actual_path)],capture_output=True,text=True)
 report=json.loads(result.stdout)
 report['target_mode']=t['mode']
 print(json.dumps(report))
 raise SystemExit(result.returncode)
