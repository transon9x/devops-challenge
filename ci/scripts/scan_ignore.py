#!/usr/bin/env python3
"""Translate a repository's scan-ignore.yml into scanner-native suppressions.

Every entry needs id, type, until and reason. Entries whose `until` date has
passed are reported and NOT applied, so the finding fails the gate again.
"""

from __future__ import annotations

import datetime as dt
import pathlib
import re
import sys

import yaml

TRIVY_SECTIONS = {
    "vulnerability": "vulnerabilities",
    "misconfiguration": "misconfigurations",
    "license": "licenses",
}
TYPES = set(TRIVY_SECTIONS) | {"semgrep"}
REQUIRED = ("id", "type", "until", "reason")
OPTIONAL = ("paths",)
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MIN_REASON = 10


def load(path: pathlib.Path) -> list[dict]:
    if not path.exists():
        return []
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict) or not isinstance(data.get("ignores", []), list):
        raise ValueError(f"{path}: top level must be a mapping with an `ignores` list")
    return data.get("ignores", [])


def validate(entry: object, index: int) -> list[str]:
    where = f"ignores[{index}]"
    if not isinstance(entry, dict):
        return [f"{where}: must be a mapping"]
    errors = []
    for key in REQUIRED:
        if key not in entry:
            errors.append(f"{where}: missing `{key}`")
    for key in entry:
        if key not in REQUIRED + OPTIONAL:
            errors.append(f"{where}: unknown key `{key}`")
    if errors:
        return errors
    if not isinstance(entry["id"], str) or not entry["id"].strip():
        errors.append(f"{where}: `id` must be a non-empty string")
    if entry["type"] not in TYPES:
        errors.append(f"{where}: `type` must be one of {sorted(TYPES)}")
    until = entry["until"]
    until_text = until.isoformat() if isinstance(until, dt.date) else str(until)
    if not DATE.match(until_text):
        errors.append(f"{where}: `until` must be YYYY-MM-DD")
    else:
        try:
            dt.date.fromisoformat(until_text)
        except ValueError:
            errors.append(f"{where}: `until` is not a real date")
    reason = entry["reason"]
    if not isinstance(reason, str) or len(reason.strip()) < MIN_REASON:
        errors.append(
            f"{where}: `reason` must be a sentence of at least {MIN_REASON} characters"
        )
    paths = entry.get("paths")
    if paths is not None:
        if entry["type"] == "semgrep":
            errors.append(f"{where}: `paths` is only valid for trivy types")
        elif not isinstance(paths, list) or not all(
            isinstance(p, str) and p for p in paths
        ):
            errors.append(f"{where}: `paths` must be a list of non-empty strings")
    return errors


def until_date(entry: dict) -> dt.date:
    until = entry["until"]
    return until if isinstance(until, dt.date) else dt.date.fromisoformat(str(until))


def render(entries: list[dict], today: dt.date) -> tuple[dict, list[str], list[dict]]:
    trivy: dict[str, list[dict]] = {}
    semgrep: list[str] = []
    expired: list[dict] = []
    for entry in entries:
        if until_date(entry) <= today:
            expired.append(entry)
            continue
        if entry["type"] == "semgrep":
            semgrep.append(entry["id"])
            continue
        item = {
            "id": entry["id"],
            "expired_at": until_date(entry),
            "statement": entry["reason"].strip(),
        }
        if entry.get("paths"):
            item["paths"] = list(entry["paths"])
        trivy.setdefault(TRIVY_SECTIONS[entry["type"]], []).append(item)
    return trivy, semgrep, expired


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: scan_ignore.py <scan-ignore.yml> <out_dir>", file=sys.stderr)
        return 2
    source = pathlib.Path(argv[1])
    out = pathlib.Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    try:
        entries = load(source)
    except (ValueError, yaml.YAMLError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 2
    errors = [e for i, entry in enumerate(entries) for e in validate(entry, i)]
    if errors:
        for error in errors:
            print(f"::error::{source}: {error}", file=sys.stderr)
        return 2

    trivy, semgrep, expired = render(entries, dt.date.today())
    (out / "trivyignore.yaml").write_text(
        yaml.safe_dump(trivy, sort_keys=True) if trivy else "{}\n"
    )
    (out / "semgrep-exclude.args").write_text(
        "".join(f"--exclude-rule\n{rule}\n" for rule in semgrep)
    )

    for entry in expired:
        print(
            f"::warning::{source}: ignore for {entry['type']} {entry['id']} expired on "
            f"{until_date(entry)} and is no longer applied ({entry['reason'].strip()})"
        )
    applied = len(entries) - len(expired)
    print(
        f"scan-ignore: {applied} suppression(s) applied, {len(expired)} expired, source {source}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
