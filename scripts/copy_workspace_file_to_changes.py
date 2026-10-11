#!/usr/bin/env python3
"""Copy generated objects into the manual changes area without overwriting files."""
import argparse
from _db_workflow import copy_workspace_file_to_changes, entrypoint


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-path", required=True,
                        help="File or directory under supabase/workspace/schemas.")
    args = parser.parse_args()
    for path in copy_workspace_file_to_changes(args.source_path):
        print(f"Copied {path}")


if __name__ == "__main__":
    entrypoint(main)
