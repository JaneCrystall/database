#!/usr/bin/env python3
"""Create a local CLI migration containing exactly the selected authored SQL.

No DROP statement is inferred and no SQL is executed. Review replacement or
destructive SQL in the selected source before applying the migration elsewhere.
"""
import argparse
from _db_workflow import entrypoint, new_migration


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="Name passed to Supabase CLI migration new.")
    parser.add_argument("--source-path", required=True, help="Explicit repository-local authored .sql file.")
    args = parser.parse_args()
    print(f"Wrote {new_migration(args.name, args.source_path)}")


if __name__ == "__main__":
    entrypoint(main)
