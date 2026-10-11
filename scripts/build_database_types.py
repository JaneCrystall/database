#!/usr/bin/env python3
"""Generate or check the TypeScript database contract from an explicit target."""
import argparse
from _db_workflow import add_database_args, build_database_types, entrypoint


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    add_database_args(parser)
    parser.add_argument("--check", action="store_true", help="Fail on type drift without changing files.")
    args = parser.parse_args()
    path = build_database_types(args.environment, args.schemas, args.check)
    print(f"{'Verified' if args.check else 'Wrote'} {path}")


if __name__ == "__main__":
    entrypoint(main)
