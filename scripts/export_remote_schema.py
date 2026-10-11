#!/usr/bin/env python3
"""Export schema SQL without applying migrations or changing database objects."""
import argparse
from _db_workflow import add_database_args, entrypoint, export_remote_schema


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    add_database_args(parser)
    parser.add_argument("--output-file", default="supabase/workspace/remote_schema.sql",
                        help="Canonical remote_schema.sql or a new .sql file under supabase/workspace/exports; authored files cannot be overwritten.")
    args = parser.parse_args()
    print(f"Wrote {export_remote_schema(args.environment, args.schemas, args.output_file)}")


if __name__ == "__main__":
    entrypoint(main)
