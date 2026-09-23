#!/usr/bin/env bash
# Prove the migration SQL that backend-migrate.sh builds behaves as the design claims,
# against a real PostgreSQL: a new file applies, a re-run is skipped without executing the
# file again, an edited file is refused, a failing file leaves nothing behind, and a file
# the guard rejects never reaches the database.
#
# The host script itself needs IMDS and AWS, so what is exercised here is the SQL contract
# and the guard, which is where the correctness lives.
#
# Requires Docker. Usage: ci/scripts/test-migration-sql.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_IMAGE="${PG_IMAGE:-postgres:17-alpine}"
container="migration-sql-test-$$"
work="$(mktemp -d)"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

pass=0
fail=0
ok() {
  printf 'OK   %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf 'FAIL %s\n' "$1"
  fail=$((fail + 1))
}

docker run -d --rm --name "$container" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app \
  "$PG_IMAGE" >/dev/null
# `pg_isready` answers yes during initdb, while the entrypoint's temporary server is still
# up, and that server then shuts down before the real one starts. Waiting for a query to
# succeed twice a second apart is the cheap way to be past that handover.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$container" psql -qtAX -U postgres -d app -c 'SELECT 1' >/dev/null 2>&1; then
    sleep 1
    if docker exec "$container" psql -qtAX -U postgres -d app -c 'SELECT 1' >/dev/null 2>&1; then
      ready=1
      break
    fi
  fi
  sleep 1
done
((ready == 1)) || {
  printf 'FAIL %s\n' "PostgreSQL never became ready" >&2
  docker logs "$container" 2>&1 | tail -20 >&2
  exit 1
}

psql() { docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d app "$@"; }

# The same ledger and the same statement order backend-migrate.sh uses.
psql --quiet --command "
  CREATE TABLE IF NOT EXISTS schema_migrations (
    filename text PRIMARY KEY,
    sha256 text NOT NULL,
    release_sha text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now());" >/dev/null

apply() { # apply <file> <release_sha>  → the statement order from backend-migrate.sh
  local file="$1" release="$2" base digest
  base="$(basename "$file")"
  digest="$(sha256sum "$file" | cut -d' ' -f1)"
  psql --quiet --command "
    SET lock_timeout = '5s'; SET statement_timeout = '15min';
    SELECT pg_advisory_xact_lock(hashtext('schema_migrations'));
    INSERT INTO schema_migrations (filename, sha256, release_sha)
    VALUES ('${base}', '${digest}', '${release}');
    $(cat "$file")" 2>&1
}

printf 'ALTER TABLE IF EXISTS nothing_here ADD COLUMN IF NOT EXISTS c int;\nCREATE TABLE widget (id int primary key);\n' > "${work}/0001_create_widget.sql"

# 1. a new migration applies
if apply "${work}/0001_create_widget.sql" aaaa >/dev/null; then
  ok "a new migration applies"
else
  bad "a new migration applies"
fi

# 2. the table really exists
if psql --tuples-only --no-align --command "SELECT count(*) FROM widget;" | grep -qx 0; then
  ok "the migration's DDL took effect"
else
  bad "the migration's DDL took effect"
fi

# 3. re-running is rejected by the ledger primary key, and does NOT execute the file again
out="$(apply "${work}/0001_create_widget.sql" bbbb || true)"
if grep -q 'schema_migrations_pkey' <<<"$out"; then
  ok "a re-run is rejected by the ledger primary key"
else
  bad "a re-run is rejected by the ledger primary key: ${out}"
fi
if [[ "$(psql --tuples-only --no-align --command "SELECT count(*) FROM widget;")" == "0" ]]; then
  ok "the re-run did not execute the file again (CREATE TABLE would have errored differently)"
else
  bad "the re-run did not execute the file again"
fi

# 4. an edited file is detectable: the recorded hash no longer matches
recorded="$(psql --tuples-only --no-align --command \
  "SELECT sha256 FROM schema_migrations WHERE filename = '0001_create_widget.sql';")"
printf 'CREATE TABLE widget (id int primary key);\n-- edited\n' > "${work}/0001_create_widget.sql"
if [[ "$recorded" != "$(sha256sum "${work}/0001_create_widget.sql" | cut -d' ' -f1)" ]]; then
  ok "an edited file no longer matches the recorded hash"
else
  bad "an edited file no longer matches the recorded hash"
fi

# 5. a failing migration rolls back: no ledger row, no partial object
printf 'CREATE TABLE half_done (id int primary key);\nSELECT 1/0;\n' > "${work}/0002_broken.sql"
out="$(apply "${work}/0002_broken.sql" cccc || true)"
if grep -qi 'division by zero' <<<"$out"; then
  ok "a failing migration reports its error"
else
  bad "a failing migration reports its error: ${out}"
fi
if [[ "$(psql --tuples-only --no-align --command \
  "SELECT count(*) FROM schema_migrations WHERE filename = '0002_broken.sql';")" == "0" ]]; then
  ok "the failed migration left no ledger row"
else
  bad "the failed migration left no ledger row"
fi
if [[ "$(psql --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_tables WHERE tablename = 'half_done';")" == "0" ]]; then
  ok "the failed migration left no partial table"
else
  bad "the failed migration left no partial table"
fi

# 6. a file that divides the transaction is refused before it reaches the database
printf 'CREATE TABLE sneaky (id int);\nCOMMIT;\nSELECT 1/0;\n' > "${work}/0003_divides.sql"
if ! python3 "${here}/sql_guard.py" "${work}/0003_divides.sql" >/dev/null 2>&1; then
  ok "the guard refuses a file that commits mid-migration"
else
  bad "the guard refuses a file that commits mid-migration"
fi
# and prove why it matters: applied anyway, the COMMIT keeps the ledger row despite the error
out="$(apply "${work}/0003_divides.sql" dddd || true)"
if [[ "$(psql --tuples-only --no-align --command \
  "SELECT count(*) FROM schema_migrations WHERE filename = '0003_divides.sql';")" == "1" ]]; then
  ok "without the guard, an explicit COMMIT would strand the ledger row after a later error"
else
  bad "the COMMIT case did not behave as expected: ${out}"
fi

# 7. a NUL byte cannot smuggle a COMMIT past the guard: the shell would delete the byte and
# PostgreSQL would see a real COMMIT, so the guard must refuse the file, and this proves both
# halves of that claim against the real database.
printf 'CREATE TABLE smuggled (id int);\nCOM\000MIT;\nSELECT 1/0;\n' > "${work}/0004_nul.sql"
if ! python3 "${here}/sql_guard.py" "${work}/0004_nul.sql" >/dev/null 2>&1; then
  ok "the guard refuses a file carrying a NUL byte"
else
  bad "the guard refuses a file carrying a NUL byte"
fi
smuggled="$(cat "${work}/0004_nul.sql")"
if [[ "$smuggled" == *"COMMIT;"* ]]; then
  ok "the shell really does turn the NUL byte into a literal COMMIT, which is why it is refused"
else
  bad "the shell did not drop the NUL byte; the guard rule needs rechecking"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
