#!/usr/bin/env python3
"""Actual resource/delete RPC race, exclusively on a gate-owned local database."""
import json
import os
import re
import selectors
import subprocess
import sys
import time
import uuid

container = sys.argv[1]
if not re.fullmatch(r"supabase_db_tiangong-ai-database-test-\d+-\d+", container):
    raise SystemExit("Refusing a non-gate container")


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def argv(application=None):
    command = ["docker", "exec", "-i"]
    if application:
        command += ["-e", "PGAPPNAME=" + application]
    return command + [container, "psql", "-XAt", "-v", "ON_ERROR_STOP=1",
                      "-v", "VERBOSITY=verbose", "-U", "postgres", "-d", "postgres"]


def sql(statement):
    result = subprocess.run(argv(), input=statement, text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""


actor, cid, request_id = [str(uuid.uuid4()) for _ in range(3)]
profile = {"id": "delete-race", "version": 1, "metadata_mode": "managed",
           "fields": {"title": "string"}, "required_fields": ["title"],
           "matching": ["unique_source_key"],
           "source_bindings": [{"id": "catalog", "kind": "metadata-snapshot"},
                               {"id": "drop", "kind": "file-snapshot"}]}
path = "delete-race-" + cid
sql(f"insert into public.kb_collections(id,name,path,metadata_schema_json) values "
    f"('{cid}','Synthetic deletion race','{path}',{quote(json.dumps({'resource_profile': profile}))}); "
    f"insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) "
    f"values('collection','{cid}','user','{actor}',array['manage']::public.kb_grant_action[],'{actor}');")


def statement(operation, payload, request=None):
    return (f"select api.kb_resource_command('{actor}','{cid}',{quote(operation)},"
            f"'{request or uuid.uuid4()}',{quote(json.dumps({'reason': 'Deletion race qualification', **payload}))}::jsonb);")


def command(operation, **payload):
    return json.loads(sql("set role service_role; " + statement(operation, payload)))


r = command("upsert", binding_id="catalog", external_key="race", expected_revision=0,
            metadata={"title": "Before deletion"})
candidate = str(uuid.uuid4())
sha256 = uuid.uuid4().hex + uuid.uuid4().hex
r = command("attach", entry_id=r["entry_id"], expected_revision=r["revision"],
            candidate={"candidate_id": candidate, "binding_id": "drop", "relative_locator": "test.pdf",
                       "sha256": sha256, "size": 811, "stable": True, "pdf_valid": True})
r = command("review", entry_id=r["entry_id"], expected_revision=r["revision"],
            decision="approve", candidate_id=candidate)
r = command("reserve", entry_id=r["entry_id"], expected_revision=r["revision"],
            approved_revision=r["approved_revision"])
relative = path + "/" + r["document_id"] + ".pdf"
r = command("publish", entry_id=r["entry_id"], expected_revision=r["revision"],
            approved_revision=r["approved_revision"], document_id=r["document_id"],
            sha256=sha256, size=811, copy_verified=True, raw_relative_path=relative,
            raw_uri="nas://raw/" + relative)
def race(operation, mutation, deleting_document, locked_job):
    request_id = str(uuid.uuid4())
    before_entry = sql(f"select to_jsonb(e) from private.kb_resource_entries e where id='{r['entry_id']}';")
    links_query = (f"select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]') "
                   f"from private.kb_resource_document_links l where entry_id='{r['entry_id']}';")
    before_links = sql(links_query)
    app_suffix = uuid.uuid4().hex
    resource_app, delete_app = "resource-race-" + app_suffix, "delete-race-" + app_suffix
    processes = []
    try:
        resource = subprocess.Popen(argv(resource_app), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
        processes.append(resource)
        # Hold the first contested lock the real resource invalidation acquires.
        # The second session executes request_delete itself, including its document
        # lock; the resource command below then executes its actual invalidation path.
        resource.stdin.write(f"begin; set local statement_timeout='10s'; "
                             f"select id from public.kb_jobs where id='{locked_job}' for update; "
                             "select 'RESOURCE_JOB_LOCKED';\n")
        resource.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(resource.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 10
        # psql's pipe is buffered; drain complete lines as readiness allows.
        output = ""
        while "RESOURCE_JOB_LOCKED" not in output:
            assert time.monotonic() < deadline, "Resource lock barrier timed out"
            if selector.select(timeout=0.1):
                chunk = os.read(resource.stdout.fileno(), 4096)
                assert chunk, "Resource session exited before lock barrier"
                output += chunk.decode()
        selector.close()
        deletion = subprocess.Popen(argv(delete_app), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
        processes.append(deletion)
        deletion.stdin.write("set statement_timeout='10s'; set role service_role; "
                             f"select job_id from public.request_delete('{deleting_document}','{actor}',"
                             "'Concurrent deletion','resource-delete-race');\n")
        deletion.stdin.close()
        deletion.stdin = None
        deadline = time.monotonic() + 8
        while sql(f"select exists(select from pg_stat_activity d join pg_stat_activity a "
                  f"on a.application_name='{resource_app}' where d.application_name='{delete_app}' "
                  "and a.pid=any(pg_blocking_pids(d.pid))); ") != "t":
            assert deletion.poll() is None, "Delete did not wait on the resource job"
            assert time.monotonic() < deadline, "Delete lock barrier timed out"
            time.sleep(0.05)
        resource.stdin.write("set local role service_role; " + statement(operation, mutation, request_id) + "\n")
        resource.stdin.close()
        resource.stdin = None
        resource_output, resource_error = resource.communicate(timeout=15)
        delete_output, delete_error = deletion.communicate(timeout=15)
        assert "40P01" not in resource_error + delete_error, (
            "Resource mutation and actual request_delete deadlocked", resource_error, delete_error)
        assert resource.returncode != 0 and "40001" in resource_error and "RESOURCE_LIFECYCLE_BUSY" in resource_error, (
            "Resource must return a bounded retryable lifecycle conflict", resource_output, resource_error)
        assert deletion.returncode == 0, delete_error
        assert sql(f"select to_jsonb(e) from private.kb_resource_entries e where id='{r['entry_id']}';") == before_entry
        assert sql(links_query) == before_links
        assert sql(f"select not exists(select from private.kb_resource_requests where request_id='{request_id}');") == "t"
        assert sql(f"select not exists(select from public.kb_audit_events where request_id='{request_id}');") == "t"
        # Retrying the identical request UUID/payload after deletion succeeds;
        # the rolled-back busy attempt must not reserve its idempotency key.
        retried = json.loads(sql("set role service_role; " + statement(operation, mutation, request_id)))
        assert retried["entry_id"] == r["entry_id"]
        assert sql(f"select status='delete_queued' and deleted_at is not null from public.kb_documents "
                   f"where id='{deleting_document}';") == "t"
        assert sql(f"select exists(select from public.kb_jobs where document_id='{deleting_document}' "
                   "and stage='delete' and status='queued');") == "t"
        print("PASS " + operation + ": actual deletion conflict rolls back and retries without resurrection", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)

race("override", {"entry_id": r["entry_id"], "expected_revision": r["revision"],
                  "fields": {"title": "After deletion"}}, r["document_id"], r["job_id"])

# Each later scenario owns a fresh collection and actual processing job.
def fresh(two_candidates=False):
    global actor, cid, path, profile, r, sha256, candidate
    actor, cid = str(uuid.uuid4()), str(uuid.uuid4())
    path = "delete-race-" + cid
    profile["version"] = 1
    sql(f"insert into public.kb_collections(id,name,path,metadata_schema_json) values "
        f"('{cid}','Synthetic deletion race','{path}',{quote(json.dumps({'resource_profile': profile}))}); "
        f"insert into public.kb_grants(resource_type,resource_id,principal_type,principal_id,actions,created_by) "
        f"values('collection','{cid}','user','{actor}',array['manage']::public.kb_grant_action[],'{actor}');")
    r = command("upsert", binding_id="catalog", external_key="race", expected_revision=0,
                metadata={"title": "Before deletion"})
    candidate = str(uuid.uuid4())
    sha256 = uuid.uuid4().hex + uuid.uuid4().hex
    r = command("attach", entry_id=r["entry_id"], expected_revision=r["revision"],
                candidate={"candidate_id": candidate, "binding_id": "drop", "relative_locator": "test.pdf",
                           "sha256": sha256, "size": 811, "stable": True, "pdf_valid": True})
    alternate = str(uuid.uuid4())
    alternate_sha = uuid.uuid4().hex + uuid.uuid4().hex
    if two_candidates:
        r = command("attach", entry_id=r["entry_id"], expected_revision=r["revision"],
                    candidate={"candidate_id": alternate, "binding_id": "drop", "relative_locator": "alternate.pdf",
                               "sha256": alternate_sha, "size": 811, "stable": True, "pdf_valid": True})
    r = command("review", entry_id=r["entry_id"], expected_revision=r["revision"],
                decision="approve", candidate_id=candidate)
    r = command("reserve", entry_id=r["entry_id"], expected_revision=r["revision"],
                approved_revision=r["approved_revision"])
    relative = path + "/" + r["document_id"] + ".pdf"
    r = command("publish", entry_id=r["entry_id"], expected_revision=r["revision"],
                approved_revision=r["approved_revision"], document_id=r["document_id"],
                sha256=sha256, size=811, copy_verified=True, raw_relative_path=relative,
                raw_uri="nas://raw/" + relative)
    return alternate, alternate_sha

fresh()
race("attach", {"entry_id": r["entry_id"], "expected_revision": r["revision"],
                "candidate": {"candidate_id": str(uuid.uuid4()), "binding_id": "drop",
                              "relative_locator": "updated.pdf", "sha256": uuid.uuid4().hex * 2,
                              "size": 811, "stable": True, "pdf_valid": True}}, r["document_id"], r["job_id"])

fresh()
sql(f"update public.kb_collections set metadata_schema_json=jsonb_set(metadata_schema_json,"
    f"'{{resource_profile,version}}','2') where id='{cid}';")
race("rebind", {"entry_id": r["entry_id"], "expected_revision": r["revision"]}, r["document_id"], r["job_id"])

fresh()
old_document, old_job = r["document_id"], r["job_id"]
r = command("review", entry_id=r["entry_id"], expected_revision=r["revision"],
            decision="approve", candidate_id=candidate)
race("reserve", {"entry_id": r["entry_id"], "expected_revision": r["revision"],
                 "approved_revision": r["approved_revision"]}, old_document, old_job)

# Switching approval to a pre-observed alternate candidate keeps the old job
# active until publication supersedes it; no synthetic resurrection is used.
alternate, alternate_sha = fresh(two_candidates=True)
old_document, old_job = r["document_id"], r["job_id"]
r = command("review", entry_id=r["entry_id"], expected_revision=r["revision"],
            decision="approve", candidate_id=alternate)
r = command("reserve", entry_id=r["entry_id"], expected_revision=r["revision"],
            approved_revision=r["approved_revision"])
relative = path + "/" + r["document_id"] + ".pdf"
race("publish", {"entry_id": r["entry_id"], "expected_revision": r["revision"],
                 "approved_revision": r["approved_revision"], "document_id": r["document_id"],
                 "sha256": alternate_sha, "size": 811, "copy_verified": True,
                 "raw_relative_path": relative, "raw_uri": "nas://raw/" + relative}, old_document, old_job)
print("Resource lifecycle/delete races qualified across five actual command paths.", flush=True)
