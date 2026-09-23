#!/usr/bin/env python3
"""Extract a verified release bundle into an empty directory, refusing anything
that is not a plain file at an allowed path. Prints "<sha256>  <path>" per file.

Two layouts: `static` is the browser bundle served from S3, `app` is the runnable
server tree a bundle-mode EC2 instance executes.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys
import tarfile

SEGMENT = r"[A-Za-z0-9@_][A-Za-z0-9._@+-]*"

LAYOUTS = {
    "static": {
        "allowed": re.compile(rf"^(index\.html|assets/(?:{SEGMENT}/)*{SEGMENT})$"),
        "required": ("index.html",),
        "min_files": 2,
    },
    "app": {
        "allowed": re.compile(
            rf"^(package\.json|package-lock\.json"
            rf"|(?:src|migrations|node_modules)/(?:{SEGMENT}/)*{SEGMENT})$"
        ),
        "required": ("package.json",),
        "min_files": 2,
    },
}
MAX_TOTAL_BYTES = 200 * 1024 * 1024
MAX_FILES = 20000


def check_member(member: tarfile.TarInfo, total: int, allowed: re.Pattern[str]) -> int:
    name = member.name[2:] if member.name.startswith("./") else member.name
    name = name.rstrip("/")
    if member.isdir():
        # A directory is allowed when some file could legally live inside it.
        if not (name in ("", ".") or allowed.match(name + "/x") or allowed.match(name)):
            raise ValueError(f"directory outside the allowed layout: {member.name}")
        return total
    if not member.isreg():
        raise ValueError(f"not a regular file: {member.name} (type {member.type!r})")
    if not allowed.match(name):
        raise ValueError(f"path outside the allowed layout: {member.name}")
    total += member.size
    if total > MAX_TOTAL_BYTES:
        raise ValueError("bundle exceeds the size limit")
    return total


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle")
    parser.add_argument("out_dir")
    parser.add_argument("--layout", choices=sorted(LAYOUTS), default="static")
    args = parser.parse_args(argv[1:])

    layout = LAYOUTS[args.layout]
    bundle, out = pathlib.Path(args.bundle), pathlib.Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        print(f"::error::{out} is not empty", file=sys.stderr)
        return 2
    try:
        with tarfile.open(bundle, "r:gz") as tar:
            members = tar.getmembers()
            if len(members) > MAX_FILES:
                raise ValueError("bundle has too many entries")
            total = 0
            for member in members:
                total = check_member(member, total, layout["allowed"])
            tar.extractall(out, filter="data")
    except (tarfile.TarError, ValueError, OSError) as exc:
        print(f"::error::refusing bundle {bundle}: {exc}", file=sys.stderr)
        return 1

    files = sorted(p for p in out.rglob("*") if p.is_file())
    for required in layout["required"]:
        if not (out / required).is_file():
            print(f"::error::bundle has no {required}", file=sys.stderr)
            return 1
    if len(files) < layout["min_files"]:
        print("::error::bundle has no payload beyond its manifest", file=sys.stderr)
        return 1
    for path in files:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{digest}  {path.relative_to(out).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
