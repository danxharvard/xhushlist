#!/usr/bin/env python3
"""Scan lists/ for blocklists and write lists.json for the website.

Each list can carry optional header comments at the top of the file:

    # Title: Ads & Trackers
    # Description: Blocks common ad and tracking domains.

If no Title is given, one is made from the filename.
Entries are counted as non-empty lines that aren't comments (# or !).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LISTS_DIR = ROOT / "lists"
OUT = ROOT / "lists.json"
EXTENSIONS = {".txt", ".hosts", ".list", ".conf"}
HEADER_LINES = 40
MAX_BYTES = 5_000_000   # some blockers refuse lists bigger than this  # how far down to look for Title/Description headers


def git_updated(path: pathlib.Path) -> str | None:
    """Last commit date for the file, or None if git isn't available."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cI", "--", str(path)],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
        return out or None
    except (OSError, subprocess.CalledProcessError):
        return None


def domains_in(text: str) -> set[str]:
    """Domains in a list, whether written one per line or as hosts lines."""
    out = set()
    for line in text.splitlines():
        parts = line.split()
        if not parts or parts[0][0] in "#!":
            continue
        if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1"):
            out.add(parts[1].lower())
        elif len(parts) == 1:
            out.add(parts[0].lower())
    return out


def last_addition(path: pathlib.Path) -> dict | None:
    """How many domains the most recent change to this list added, and when.

    Compares the list with its previous committed version. Returns None when git
    history isn't available or the latest change added nothing.
    """
    rel = path.relative_to(ROOT).as_posix()
    try:
        commits = subprocess.run(["git", "log", "-2", "--format=%H %cI", "--", rel],
                                 cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
        commits = [c.split() for c in commits if c.strip()]
        if len(commits) < 2:
            return None
        before = subprocess.run(["git", "show", f"{commits[1][0]}:{rel}"],
                                cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    added = len(domains_in(path.read_text(encoding="utf-8", errors="replace")) - domains_in(before))
    return {"count": added, "date": commits[0][1]} if added else None


def describe(path: pathlib.Path) -> dict:
    meta = {}
    entries = 0
    with path.open(encoding="utf-8", errors="replace") as f:
        for i, raw in enumerate(f):
            line = raw.strip()
            if not line:
                continue
            if line[0] in "#!":
                if i < HEADER_LINES:
                    body = line.lstrip("#! ").strip()
                    key, sep, value = body.partition(":")
                    if sep and key.strip().lower() in ("title", "description"):
                        meta.setdefault(key.strip().lower(), value.strip())
                continue
            entries += 1

    updated = git_updated(path) or dt.datetime.fromtimestamp(
        path.stat().st_mtime, dt.timezone.utc).isoformat()
    title = meta.get("title") or path.stem.replace("-", " ").replace("_", " ").title()

    info = {
        "title": title,
        "description": meta.get("description", ""),
        "path": path.relative_to(ROOT).as_posix(),
        "entries": entries,
        "size": path.stat().st_size,
        "updated": updated,
    }
    added = last_addition(path)
    if added:
        info["added"] = added
    return info


def main() -> int:
    LISTS_DIR.mkdir(exist_ok=True)
    files = sorted(p for p in LISTS_DIR.iterdir()
                   if p.is_file() and p.suffix.lower() in EXTENSIONS)
    # Some blockers can't load lists over 5 MB: refuse to publish one.
    too_big = [f"{p.name} ({p.stat().st_size / 1e6:.2f} MB)" for p in files if p.stat().st_size > MAX_BYTES]
    if too_big:
        print("error: over the 5 MB limit some blockers have: " + ", ".join(too_big), file=sys.stderr)
        return 1
    lists = [describe(p) for p in files]
    # A tiny checksum file next to each list lets installed copies skip the download
    # when nothing changed, and check the download arrived intact.
    for p in files:
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        p.with_name(p.name + ".sha256").write_text(digest + "\n", encoding="utf-8")
    manifest = {
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "lists": lists,
    }
    OUT.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for l in lists:
        print(f"  {l['path']}: {l['entries']:,} entries")
    print(f"Wrote {OUT.name} with {len(lists)} list(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
