#!/usr/bin/env python3
"""Additive-only migration guard for the familyfocal sync contract.

A published app version talks to the server through a fixed contract: the
columns it reads/writes and the tables it expects. Once an app build ships,
that contract must keep being satisfiable by every future server. This guard
fails the build if a migration would break it.

Two invariants, checked across *all* files in supabase/migrations:

  1. No contract-breaking DDL. Forbidden because an already-installed app
     would start failing against a server that applied it:
       - DROP TABLE / DROP COLUMN          (removes something the app uses)
       - RENAME (table or column)          (same, under a new name)
       - column TYPE change                (breaks the wire format)
       - SET NOT NULL on an existing column / ADD COLUMN NOT NULL w/o DEFAULT
                                           (old clients omit it on INSERT)

  2. Every table created in the familyfocal schema has RLS enabled somewhere.
     A familyfocal table without row-level security is readable/writable by
     any tenant — a cross-family data leak the moment the cloud is shared.

Deliberately ALLOWED (forward-compatible, used by the existing tree):
  - DROP POLICY        — RLS policies are not part of the app data contract.
  - DROP CONSTRAINT    — only ever loosens what's accepted; old writes still
                         succeed (e.g. widening a CHECK to add a new value).
  - ADD COLUMN ... (nullable, or NOT NULL DEFAULT ...) — the additive path.

Usage:  scripts/check_migrations.py [migrations_dir]
Exit 0 if clean, 1 if any violation. Any file arguments are ignored — the
guard always validates the whole migration set, so editing an old file is
caught too.
"""

import glob
import os
import re
import sys

SCHEMA = "familyfocal"


def strip_and_split(sql: str):
    """Yield normalized statements (lowercased, whitespace-collapsed).

    Comment- and quote-aware: removes -- and /* */ comments, keeps the content
    of '...' strings and $tag$...$tag$ dollar-quoted bodies intact, and splits
    on semicolons only at the top level (not inside strings or dollar quotes).
    """
    out = []
    i, n = 0, len(sql)
    buf = []
    while i < n:
        ch = sql[i]
        two = sql[i:i + 2]
        # line comment
        if two == "--":
            j = sql.find("\n", i)
            i = n if j == -1 else j
            continue
        # block comment
        if two == "/*":
            j = sql.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        # single-quoted string: copy verbatim, handle '' escape
        if ch == "'":
            buf.append(ch)
            i += 1
            while i < n:
                buf.append(sql[i])
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        buf.append(sql[i + 1])
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        # dollar-quoted block: $tag$ ... $tag$
        if ch == "$":
            m = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$", sql[i:])
            if m:
                tag = m.group(0)
                end = sql.find(tag, i + len(tag))
                end = n if end == -1 else end + len(tag)
                buf.append(sql[i:end])
                i = end
                continue
        # statement terminator
        if ch == ";":
            out.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if buf:
        out.append("".join(buf))

    for raw in out:
        norm = re.sub(r"\s+", " ", raw).strip().lower()
        if norm:
            yield norm


def forbidden_ddl(stmt: str):
    """Return a human-readable reason if stmt breaks the contract, else None."""
    if re.search(r"\bdrop\s+table\b", stmt):
        return "DROP TABLE removes a table the published app depends on"
    if re.search(r"\bdrop\s+column\b", stmt):
        return "DROP COLUMN removes a column the published app reads/writes"
    if stmt.startswith("alter ") and re.search(r"\brename\b", stmt):
        return "RENAME makes a table/column disappear under its old name"
    if re.search(r"\bset\s+data\s+type\b", stmt) or re.search(
        r"\balter\s+column\s+\S+\s+type\b", stmt
    ):
        return "column TYPE change breaks the wire format for old clients"
    if re.search(r"\bset\s+not\s+null\b", stmt):
        return "SET NOT NULL rejects INSERTs from clients that omit the column"
    if (
        re.search(r"\badd\s+column\b", stmt)
        and re.search(r"\bnot\s+null\b", stmt)
        and not re.search(r"\bdefault\b", stmt)
    ):
        return "ADD COLUMN NOT NULL without DEFAULT fails INSERTs from old clients"
    return None


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default_dir = os.path.join(os.path.dirname(here), "supabase", "migrations")
    mig_dir = sys.argv[1] if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else default_dir

    files = sorted(glob.glob(os.path.join(mig_dir, "*.sql")))
    if not files:
        print(f"check-migrations: no .sql files in {mig_dir}", file=sys.stderr)
        return 1

    violations = []
    created = {}   # table -> file where created
    rls_on = set()

    create_re = re.compile(
        r"create\s+table\s+(?:if\s+not\s+exists\s+)?" + SCHEMA + r"\.(\w+)"
    )
    rls_re = re.compile(
        r"alter\s+table\s+(?:only\s+)?" + SCHEMA + r"\.(\w+)\s+enable\s+row\s+level\s+security"
    )

    for path in files:
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            sql = fh.read()
        for stmt in strip_and_split(sql):
            reason = forbidden_ddl(stmt)
            if reason:
                snippet = stmt[:80] + ("…" if len(stmt) > 80 else "")
                violations.append(f"{name}: {reason}\n    → {snippet}")
            m = create_re.search(stmt)
            if m and stmt.startswith("create table"):
                created.setdefault(m.group(1), name)
            m = rls_re.search(stmt)
            if m:
                rls_on.add(m.group(1))

    missing_rls = sorted(t for t in created if t not in rls_on)
    for t in missing_rls:
        violations.append(
            f"{created[t]}: table {SCHEMA}.{t} has no 'enable row level security' "
            f"in any migration — cross-tenant leak risk"
        )

    if violations:
        print("✗ migration guard FAILED — these break the published-app contract:\n")
        for v in violations:
            print("  • " + v)
        print(
            "\nAdditive-only rule: add nullable columns (or NOT NULL DEFAULT …), "
            "never remove/rename/retype what a shipped app uses. Enable RLS on every "
            f"{SCHEMA} table. See docs/cloud-vs-selfhost.md."
        )
        return 1

    print(
        f"✓ migration guard passed — {len(files)} files, "
        f"{len(created)} tables, all RLS-enabled, no contract-breaking DDL"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
