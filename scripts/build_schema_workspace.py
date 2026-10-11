#!/usr/bin/env python3
"""Build generated schema object views while preserving manual changes."""
import argparse
from _db_workflow import add_database_args, build_schema_workspace, entrypoint


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    add_database_args(parser)
    parser.add_argument("--schema-file", help="Offline SQL input; no CLI or database connection is used.")
    args = parser.parse_args()
    if args.schema_file and args.environment != "local":
        parser.error("--schema-file cannot be combined with a remote environment")
    print(f"Built {build_schema_workspace(args.environment, args.schemas, args.schema_file)}")


if __name__ == "__main__":
    entrypoint(main)
