#!/usr/bin/env python3
"""Exercise real KB journal collectors/writers on validated disposable DB targets.

Run with the KB uv Python environment. Only Crossref HTTP transports are mocked;
SQLAlchemy introspection, psycopg2 inserts, candidate queries and guarded writes
run against the actual local/verified-preview database. No host .env is loaded.
"""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid

from runtime import load_private, validate_target

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent


def run(target: dict, kb_root: Path, skills_root: Path) -> dict:
    validate_target(target)  # Must precede imports/configuration and every DB write.
    kb_journals = kb_root / "src/file_processing/journals"
    if not (kb_journals / "collect_metadata.py").is_file():
        raise RuntimeError("Actual KB journal source is unavailable")
    run_id = target["run_id"]
    dois = [f"10.99999/{run_id}-journal-{number}" for number in (1, 2)]
    journal = f"SYNTHETIC DATABASE CONSUMER {run_id}"
    issn = f"{int(run_id[:4], 16) % 10000:04d}-{int(run_id[4:8], 16) % 10000:04d}"
    issn_id = str(uuid.uuid4())
    existing_abstract = "Synthetic existing abstract must remain unchanged."
    backfill_abstract = "Synthetic backfilled abstract from mocked Crossref."
    prior_environment = dict(os.environ)
    connection = None
    fixture_created = False
    with tempfile.TemporaryDirectory(prefix="tiangong-journal-consumer-") as directory:
        temporary = Path(directory)
        empty_env = temporary / "empty.env"
        empty_env.write_text("")
        isolated_skills = temporary / "skills"
        for skill, filename in (("fetch-meta-to-kb", "fetch_meta_to_kb.py"), ("fetch-abstract-to-kb", "fetch_abstract_to_kb.py")):
            source = skills_root / skill / "scripts" / filename
            if not source.is_file():
                raise RuntimeError("Actual reusable journal skill source is unavailable")
            destination = isolated_skills / skill / "scripts" / filename
            destination.parent.mkdir(parents=True)
            shutil.copyfile(source, destination)
            if source.read_bytes() != destination.read_bytes():
                raise AssertionError("Skill source copy changed bytes")
        bootstrap = temporary / "bootstrap"
        bootstrap.mkdir()
        shutil.copyfile(Path(__file__).with_name("journal_network_mock.py"), bootstrap / "journal_network_mock.py")
        (bootstrap / "sitecustomize.py").write_text("from journal_network_mock import install\ninstall()\n")
        fixture = temporary / "crossref.json"
        items = []
        for index, doi in enumerate(dois):
            item = {"DOI": doi, "title": [f"Synthetic collector article {index + 1}"], "container-title": [journal], "author": [{"given": "Synthetic", "family": "Author"}], "issued": {"date-parts": [[2026, 10]]}}
            if index == 1:
                item["abstract"] = existing_abstract
            items.append(item)
        fixture.write_text(json.dumps({"issn": issn, "metadata_items": items, "resolved_abstracts": {dois[0]: "<jats:p>" + backfill_abstract + "</jats:p>"}}))
        audit = temporary / "transport-audit.jsonl"
        allowed_environment = {key: value for key, value in prior_environment.items() if key in ("PATH", "LANG", "LC_ALL", "TMPDIR", "SYSTEMROOT")}
        environment = {**allowed_environment, "DATABASE_URL": target["db_url"], "KB_ENV_FILE": str(empty_env), "PYTHON_DOTENV_DISABLED": "1", "KB_SKILLS_DIR": str(isolated_skills), "KB_LOG_DIR": str(temporary / "logs"), "KB_ABSTRACT_STATE_PATH": str(temporary / "abstract-state.json"), "PYTHONPATH": str(bootstrap), "JOURNAL_CONSUMER_TRANSPORT_FIXTURE": str(fixture), "JOURNAL_CONSUMER_TRANSPORT_AUDIT": str(audit)}
        try:
            os.environ.clear()
            os.environ.update(environment)
            import psycopg2
            from psycopg2.extensions import parse_dsn

            settings = parse_dsn(target["db_url"])
            for source_key, env_key in {"host": "KB_DB_HOST", "port": "KB_DB_PORT", "dbname": "KB_DB_NAME", "user": "KB_DB_USER", "password": "KB_DB_PASSWORD", "sslmode": "PGSSLMODE"}.items():
                if settings.get(source_key):
                    os.environ[env_key] = settings[source_key]
            os.environ.setdefault("KB_DB_PORT", "5432")
            os.environ.setdefault("KB_DB_NAME", "postgres")
            os.environ.setdefault("PGSSLMODE", "disable" if target["mode"] == "local" else "require")
            connection = psycopg2.connect(target["db_url"], connect_timeout=15)
            with connection.cursor() as cursor:
                cursor.execute("SELECT count(*) FROM public.journals WHERE doi = ANY(%s)", (dois,))
                assert cursor.fetchone()[0] == 0, "Fixture DOI already exists; refusing reuse"
                cursor.execute("INSERT INTO public.journals_issn(id,journal,issn1) VALUES (%s,%s,%s)", (issn_id, journal, issn))
            connection.commit()
            fixture_created = True

            sys.path.insert(0, str(kb_journals))
            from journal_network_mock import install
            install()  # Parent process urllib transport; child gets sitecustomize.
            import collect_metadata
            import kb_abstract_pipeline as pipeline

            summaries = []
            for expected in (2, 0):
                prior_argv = sys.argv
                try:
                    sys.argv = ["collect_metadata.py", "--from-date", "2000-01-01", "--command-timeout", "120"]
                    with redirect_stdout(io.StringIO()):
                        assert collect_metadata.main() == 0, "Actual KB metadata collector failed"
                finally:
                    sys.argv = prior_argv
                result = json.loads((temporary / "logs/kb-meta-run-result.json").read_text())
                assert result["ok"] and result["summary"]["completed"]
                assert result["summary"]["total_inserted"] == expected, "Collector DOI deduplication changed"
                summaries.append(expected)
            with connection.cursor() as cursor:
                cursor.execute("SELECT doi,authors,abstract FROM public.journals WHERE doi=ANY(%s) ORDER BY doi", (dois,))
                collected = cursor.fetchall()
            connection.rollback()
            assert len(collected) == 2
            assert all(row[1] == ["Synthetic Author"] for row in collected)
            assert next(row[2] for row in collected if row[0] == dois[1]) == existing_abstract

            readonly = pipeline.database_connection(readonly=True)
            try:
                # Exercise the actual keyset query/column introspection, then
                # restrict eligible writes to this test's exact fixture DOIs.
                owned_rows = [row for row in pipeline.database_rows(readonly) if row["doi"] in dois]
            finally:
                readonly.close()
            candidates, _ = pipeline.select_candidates(owned_rows, {"version": 1, "dois": {}}, 2)
            assert [row["doi"] for row in candidates] == [dois[0]], "Candidate scan included an existing abstract"
            successes, failures, _ = pipeline.resolve_candidates(candidates, timeout=5)
            assert not failures and len(successes) == 1
            assert successes[0]["abstract"] == backfill_abstract
            outcome = pipeline.write_abstracts(successes + [{"doi": dois[1], "abstract": "Must not replace existing abstract"}])
            assert outcome["ok"]
            assert outcome["result"]["updated"] == 1 and outcome["result"]["already_present"] == 1
            repeated = pipeline.write_abstracts(successes)
            assert repeated["ok"] and repeated["result"]["updated"] == 0 and repeated["result"]["already_present"] == 1
            with connection.cursor() as cursor:
                cursor.execute("SELECT doi,abstract FROM public.journals WHERE doi=ANY(%s)", (dois,))
                abstracts = dict(cursor.fetchall())
            connection.rollback()
            assert abstracts == {dois[0]: backfill_abstract, dois[1]: existing_abstract}
            transports = [json.loads(line)["transport"] for line in audit.read_text().splitlines()]
            assert transports.count("metadata_crossref") >= 4 and transports.count("abstract_crossref") == 1
            return {"consumer": "journals", "ok": True, "mode": target["mode"], "run_id": run_id, "metadata_insert_counts": summaries, "authors_jsonb_roundtrip": True, "candidate_count": len(candidates), "abstracts_updated": 1, "existing_abstract_preserved": True, "guarded_repeat_updated": 0, "transport_only_mocked": True, "fixtures_cleaned": True}
        finally:
            try:
                if connection is not None:
                    try:
                        connection.rollback()
                        if fixture_created:
                            with connection.cursor() as cursor:
                                cursor.execute("DELETE FROM public.journals WHERE doi=ANY(%s)", (dois,))
                                cursor.execute("DELETE FROM public.journals_issn WHERE id=%s AND journal=%s", (issn_id, journal))
                            connection.commit()
                            with connection.cursor() as cursor:
                                cursor.execute("SELECT count(*) FROM public.journals WHERE doi=ANY(%s)", (dois,))
                                assert cursor.fetchone()[0] == 0
                                cursor.execute("SELECT count(*) FROM public.journals_issn WHERE id=%s", (issn_id,))
                                assert cursor.fetchone()[0] == 0
                            connection.rollback()
                    finally:
                        connection.close()
            finally:
                os.environ.clear()
                os.environ.update(prior_environment)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, type=Path, help="Private disposable runtime target.json")
    parser.add_argument("--kb-root", type=Path, default=WORKSPACE / "TianGong-AI-KB")
    parser.add_argument("--skills-root", type=Path, default=WORKSPACE / "skills")
    arguments = parser.parse_args()
    try:
        target = load_private(arguments.target)
        result = run(target, arguments.kb_root.resolve(), arguments.skills_root.resolve())
    except Exception as error:
        print(json.dumps({"consumer": "journals", "ok": False, "error_type": type(error).__name__, "error": "Journal consumer validation failed; exception details withheld to protect target credentials."}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
