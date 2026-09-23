#!/usr/bin/env python3
"""Refuse migration files that would break the one-transaction-per-file guarantee.

The pipeline runs this before publishing and the migration host runs the same file before
applying anything, so the rules cannot drift apart. It is a guardrail in front of review,
not a proof: string literals and comments are removed before scanning, which catches the
shapes that hide a transaction statement, but a determined author can still write something
this does not recognise, which is why `migrations/` is CODEOWNERS-gated.

Usage: sql_guard.py <file.sql>   → prints nothing and exits 0 when the file is acceptable.
"""

from __future__ import annotations

import pathlib
import re
import sys

TRANSACTION = re.compile(
    r"(?:^|;)\s*"
    r"(BEGIN|START\s+TRANSACTION|COMMIT(\s+AND\s+(NO\s+)?CHAIN)?|END|ROLLBACK|ABORT"
    r"|SAVEPOINT|RELEASE(\s+SAVEPOINT)?|SET\s+TRANSACTION|SET\s+CONSTRAINTS)"
    r"(?=\s|;|$)",
    re.I,
)
META_COMMAND = re.compile(r"^\s*\\", re.M)
DOLLAR_TAG = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
# PostgreSQL's scanner treats every byte above ASCII as an identifier character, without
# asking what the code point means, so a combining mark continues an identifier exactly as a
# letter does and `e` + U+0301 + `$x$` is one identifier. Python's `\w` would stop at the
# mark, read `$x$` as a dollar quote and swallow whatever followed, so the classes below are
# byte-level rather than Unicode-aware. `$` continues an identifier too, which is why
# `foo$x$` is one identifier and not `foo` followed by a dollar quote.
IDENT_START = re.compile(r"[A-Za-z_\u0080-\U0010ffff]")
IDENT_CONT = re.compile(r"[A-Za-z0-9_$\u0080-\U0010ffff]")
IDENTIFIER = re.compile(r"[A-Za-z_\u0080-\U0010ffff][A-Za-z0-9_$\u0080-\U0010ffff]*")


def normalise(sql: str) -> str:
    """Replace every literal and comment with a placeholder, in one left-to-right pass.

    A pass per construct cannot work: `SELECT '$x$'; COMMIT; SELECT '$x$';` would let a
    dollar-quote pattern span two ordinary strings and swallow the statement between them.
    Scanning once, taking whichever construct starts at the cursor, makes that impossible.
    """
    out: list[str] = []
    i, n = 0, len(sql)
    while i < n:
        char = sql[i]
        # E'...' escape string: a backslash escapes the next character.
        if char in "eE" and i + 1 < n and sql[i + 1] == "'":
            i += 2
            while i < n:
                if sql[i] == "\\":
                    i += 2
                    continue
                if sql[i] == "'":
                    if sql.startswith("''", i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(" '' ")
            continue
        if char == "'":
            i += 1
            while i < n:
                if sql[i] == "'":
                    if sql.startswith("''", i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(" '' ")
            continue
        if char == '"':
            i += 1
            while i < n:
                if sql[i] == '"':
                    if sql.startswith('""', i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(" ident ")
            continue
        if sql.startswith("--", i):
            newline = sql.find("\n", i)
            i = n if newline < 0 else newline
            out.append(" ")
            continue
        if sql.startswith("/*", i):
            depth, i = 1, i + 2  # PostgreSQL block comments nest
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth += 1
                    i += 2
                elif sql.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(" ")
            continue
        if IDENT_START.match(char):
            word = IDENTIFIER.match(sql, i)
            if word:
                out.append(word.group(0))
                i = word.end()
                continue
        if char == "$":
            # A `$` directly after an identifier character does not open a dollar quote
            # here. Most such cases are already consumed by the identifier branch, because
            # PostgreSQL's longest-match scanner reads `foo$x$` as one identifier. The
            # leftovers are a `$` after a digit or a quoted identifier, where PostgreSQL
            # would take the dollar quote; refusing to is the safe direction, since the
            # alternative is to delete text across a token boundary we are unsure of, and
            # the cost is rejecting a file that would not parse anyway.
            after_identifier = i > 0 and bool(IDENT_CONT.match(sql[i - 1]))
            tag = None if after_identifier else DOLLAR_TAG.match(sql, i)
            if tag:
                closing = sql.find(tag.group(0), tag.end())
                i = n if closing < 0 else closing + len(tag.group(0))
                out.append(" '' ")
                continue
        out.append(char)
        i += 1
    return re.sub(r"\s+", " ", "".join(out))


def problems(path: pathlib.Path) -> list[str]:
    raw = path.read_text(errors="replace")
    found = []
    if "\x00" in raw:
        # The migration host passes the file's text through a command substitution, and bash
        # drops NUL bytes from one silently. `COM<NUL>MIT` would therefore reach PostgreSQL as
        # `COMMIT` while reading here as something this scanner does not recognise, so the byte
        # has to be refused rather than normalised away.
        found.append(
            "contains a NUL byte; the text is passed through a shell command substitution, "
            "which would delete it and change what PostgreSQL executes"
        )
    if META_COMMAND.search(raw):
        found.append(
            "contains a psql meta-command; migrations are plain SQL, and a meta-command "
            "would run outside the transaction"
        )
    match = TRANSACTION.search(normalise(raw))
    if match:
        found.append(
            f"manages its own transaction ({match.group(1).strip()}); the migration job "
            "owns the transaction, and dividing it breaks the all-or-nothing guarantee"
        )
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: sql_guard.py <file.sql>", file=sys.stderr)
        return 2
    path = pathlib.Path(argv[1])
    found = problems(path)
    for problem in found:
        print(f"{path.name}: {problem}", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
