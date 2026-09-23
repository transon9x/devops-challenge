#!/usr/bin/env bash
# Migration authoring rules, checked in the pipeline so the job on the host is not the first
# place a bad file is noticed. Expand-only is a contract between authors, not something a
# pipeline can prove; what this check can do is refuse the shapes that break it silently and
# make a contracting change declare itself. It is a guardrail in front of review, not a
# substitute for it: a determined author can still write a destructive statement it does not
# recognise, which is why `migrations/` is CODEOWNERS-gated.
#
# Required env: APP_DIR
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${APP_DIR:?}"
dir="${APP_DIR}/migrations"
if [[ ! -d "$dir" ]]; then
  say "no migrations/ directory in ${APP_DIR}: nothing to check"
  exit 0
fi

shopt -s nullglob
files=("$dir"/*.sql)
shopt -u nullglob
if ((${#files[@]} == 0)); then
  say "no migration files in ${dir}"
  exit 0
fi

# A contracting change (dropping or narrowing something the running release may still use)
# is allowed only when the file says so, which is what a reviewer is asked to confirm. The
# text is normalised by the same guard the migration host uses, so a destructive statement
# cannot hide inside a comment or a string.
CONTRACT_MARKER='^[[:space:]]*--[[:space:]]*phase:[[:space:]]*contract([[:space:]]|$)'
DESTRUCTIVE='DROP[[:space:]]+(TABLE|VIEW|COLUMN|CONSTRAINT|INDEX|TYPE|SCHEMA|SEQUENCE)|ALTER[[:space:]]+TABLE[^;]*DROP|RENAME[[:space:]]+(TO|COLUMN|CONSTRAINT)|SET[[:space:]]+NOT[[:space:]]+NULL|SET[[:space:]]+DATA[[:space:]]+TYPE|TRUNCATE[[:space:]]'

problems=0
for file in "${files[@]}"; do
  name="${file##*/}"
  # A fixed-width, zero-padded prefix and a real lower_snake_case name, so lexicographic
  # order is numeric order: 0010_… sorts before 0100_…, while 10_… would not.
  if [[ ! "$name" =~ ^[0-9]{4}_[a-z][a-z0-9]*(_[a-z0-9]+)*\.sql$ ]]; then
    warn "::error file=${file}::name must be NNNN_lower_snake_case.sql with a four-digit zero-padded prefix, so file order is unambiguous"
    problems=$((problems + 1))
  fi
  if ! guard="$(python3 "${here}/sql_guard.py" "$file" 2>&1)"; then
    warn "::error file=${file}::${guard#*: }"
    problems=$((problems + 1))
  fi
  body="$(python3 -c 'import pathlib,sys; sys.path.insert(0, sys.argv[1]); import sql_guard; print(sql_guard.normalise(pathlib.Path(sys.argv[2]).read_text()))' "$here" "$file")"
  # A gate must not pass because a search failed to run. grep exits 1 for "no match" and
  # above 1 for an error, so anything above 1 is fatal rather than a clean bill of health.
  destructive=0
  printf '%s\n' "$body" | grep -qiE "$DESTRUCTIVE" || destructive=$?
  ((destructive <= 1)) || die "could not scan ${file} for contracting statements (grep exited ${destructive})"
  declared=0
  grep -qiE "$CONTRACT_MARKER" "$file" || declared=$?
  ((declared <= 1)) || die "could not read ${file} to look for its phase declaration (grep exited ${declared})"
  if ((destructive == 0)) && ((declared != 0)); then
    warn "::error file=${file}::this looks like a contracting change; if the old schema is genuinely unused, declare it with a '-- phase: contract' line and have it reviewed"
    problems=$((problems + 1))
  fi
done

((problems == 0)) || die "${problems} migration problem(s) in ${dir}"
say "migration check passed for ${#files[@]} file(s)"
