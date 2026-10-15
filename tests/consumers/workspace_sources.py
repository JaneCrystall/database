"""Locate reviewed sibling sources across current and older workspace layouts."""
from pathlib import Path


def sibling_source(workspace: Path, canonical: str, legacy: str) -> Path:
    """Prefer the current directory, falling back only to an existing legacy one."""
    current = workspace / canonical
    previous = workspace / legacy
    if current.is_dir() or not previous.is_dir():
        return current
    return previous
