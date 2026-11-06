#!/usr/bin/env python3
"""Download upstream blocklists and convert them to hosts format in lists/.

Each [section] in sources.ini becomes lists/<name>.txt. Adblock-style
rules (||example.com^) and plain domain lines are both understood; anything
more complex (paths, cosmetic rules, exceptions) is skipped because it can't
be expressed in a hosts file.

Upstream lists are credited in the output header. Keep the licence and
source lines: licences such as the GPL require them when you redistribute a list.
"""
from __future__ import annotations

import configparser
import datetime as dt
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LISTS_DIR = ROOT / "lists"

SOURCES = ROOT / "sources.ini"
NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def load_sources() -> list[dict]:
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(SOURCES, encoding="utf-8")
    out = []
    for name in cp.sections():
        sec = cp[name]
        if not NAME.match(name):
            raise SystemExit(f"sources.ini: [{name}] must be lowercase letters, numbers and dashes")
        if not sec.get("url"):
            raise SystemExit(f"sources.ini: [{name}] has no url")
        out.append({
            "name": name,
            "url": sec["url"].strip(),
            "title": sec.get("title", "").strip() or name.replace("-", " ").title(),
            "description": sec.get("description", "").strip(),
            "credit": sec.get("credit", "").strip(),
            "license": sec.get("license", "").strip(),
        })
    return out

DOMAIN = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def to_domain(line: str) -> str | None:
    line = line.strip().lower()
    if not line or line[0] in "!#[":
        return None
    if line.startswith("@@"):                      # allow-rules: not representable
        return None
    if line.startswith("||") and line.endswith("^"):
        line = line[2:-1]
    else:
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1", "::", "::1"):
            line = parts[1]
        elif len(parts) != 1:
            return None
    return line if DOMAIN.match(line) else None


def sync(up: dict) -> None:
    req = urllib.request.Request(up["url"], headers={"User-Agent": "blocklist-sync/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        text = r.read().decode("utf-8", errors="replace")

    seen = set()
    domains = []
    for raw in text.splitlines():
        d = to_domain(raw)
        if d and d not in seen:
            seen.add(d)
            domains.append(d)
    if len(domains) < 1000:
        raise SystemExit(f"{up['url']} returned only {len(domains)} domains; refusing to overwrite")

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    header = [
        f"# Title: {up['title']}",
        f"# Description: {up['description']}",
        f"# Source: {up['url']}",
    ]
    if up["credit"]:
        header.append(f"# Credit: {up['credit']}")
    if up["license"]:
        header.append(f"# License: {up['license']}")
    header += [
        f"# Converted: {now}",
        f"# Entries: {len(domains)}",
        "# Note: hosts format blocks exact domains only, not their subdomains.",
        "",
    ]
    out = LISTS_DIR / f"{up['name']}.txt"
    LISTS_DIR.mkdir(exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header) + "\n".join("0.0.0.0 " + d for d in domains) + "\n")
    print(f"  {out.relative_to(ROOT)}: {len(domains):,} domains")


def main() -> int:
    failed = []
    for up in load_sources():
        try:
            sync(up)
        except (Exception, SystemExit) as e:  # one broken source shouldn't stop the others
            print(f"  [{up['name']}] FAILED: {e}", file=sys.stderr)
            failed.append(up["name"])
    if failed:
        print(f"Failed: {', '.join(failed)}", file=sys.stderr)
        # Let GitHub Actions fail the job so a partial/stale build is not deployed.
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
