"""Synthetic Crossref transport only; journal SQL and application code stay real."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlsplit


def install() -> None:
    fixture = json.loads(Path(os.environ["JOURNAL_CONSUMER_TRANSPORT_FIXTURE"]).read_text())
    audit = Path(os.environ["JOURNAL_CONSUMER_TRANSPORT_AUDIT"])

    def record(kind: str) -> None:
        with audit.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"transport": kind}) + "\n")

    class Response:
        status_code = 200

        def __init__(self, payload):
            self.payload = payload

        def raise_for_status(self):
            return None

        def json(self):
            return self.payload

    def requests_get(url, params=None, **_kwargs):
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.crossref.org" or not parsed.path.startswith("/journals/") or not parsed.path.endswith("/works"):
            raise RuntimeError("Consumer test forbids unmocked provider transport")
        record("metadata_crossref")
        # Real collector scans all configured ISSNs on the disposable target.
        # Return no articles for another test's journal; never ingest its data.
        if parsed.path != f"/journals/{fixture['issn']}/works" or (params or {}).get("cursor") != "*":
            return Response({"message": {"items": []}})
        return Response({"message": {"items": fixture["metadata_items"], "next-cursor": "consumer-next"}})

    def urlopen(request, **_kwargs):
        url = request.full_url if hasattr(request, "full_url") else str(request)
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.crossref.org" or not parsed.path.startswith("/works/"):
            raise RuntimeError("Consumer test forbids unmocked provider transport")
        doi = unquote(parsed.path.removeprefix("/works/"))
        abstract = fixture["resolved_abstracts"].get(doi)
        if abstract is None:
            raise RuntimeError("Consumer test forbids provider lookup for nonfixture DOI")
        record("abstract_crossref")
        return io.BytesIO(json.dumps({"message": {"title": ["Synthetic journal consumer article"], "abstract": abstract}}).encode())

    import requests
    import urllib.request

    requests.get = requests_get
    urllib.request.urlopen = urlopen
