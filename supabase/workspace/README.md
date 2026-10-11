# Schema inspection workspace

`remote_schema.sql`, `global/` and `schemas/` are ignored generated files.
Refresh them with `python3 scripts/build_schema_workspace.py --help` guidance.
Never use the object-file order as a database restore sequence.

`changes/` is the durable, versioned editing overlay. Copy objects there before
editing; refresh preserves the directory. Review explicit migration SQL before
writing it to the authoritative migration history. See
[development](../../docs/development.md) from the repository root documentation.
