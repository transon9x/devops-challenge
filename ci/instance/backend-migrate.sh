#!/usr/bin/env bash
# Baked into the migration AMI at /opt/backend/migrate.sh and run once by
# backend-migrate.service on the ephemeral host the runbook launches. The pipeline never
# connects to the database: it only asks for this job to run.
#
# Reads the release digest and the result parameter from its own instance tags, verifies
# the release was built by the shared pipeline, applies the migrations that release carries,
# publishes the outcome to Parameter Store; the runbook terminates the host.
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/backend/bootstrap.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${IMAGE_REPOSITORY:?}" "${TEMPLATE_REPO:?}" "${SOURCE_REPO:?}" "${CONFIG_PARAMETER_PATH:?}" "${AWS_REGION:?}"
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
RUN_DIR="${RUN_DIR:-/run/backend-migrate}"
# systemd's StateDirectory, owned by the migrator: /opt/backend stays root-owned and
# read-only, so the job cannot alter what a serving fleet would run.
RELEASE_DIR="${RELEASE_DIR:-/var/lib/backend-migrate/release}"
IMDS="http://169.254.169.254/latest"
# A migration that cannot take its locks quickly is abandoned, never left blocking the fleet.
LOCK_TIMEOUT="${LOCK_TIMEOUT:-5s}"
STATEMENT_TIMEOUT="${STATEMENT_TIMEOUT:-15min}"

log() { printf 'backend-migrate: %s\n' "$*"; }

token="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' "${IMDS}/api/token")"
imds() { curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "${IMDS}/meta-data/$1"; }

digest="$(imds tags/instance/app:artifact-digest)"
result_param="$(imds tags/instance/app:result-parameter)"
release_sha="$(imds tags/instance/app:release)"
instance_id="$(imds instance-id)"

publish() { # <ok|failed> <detail>
  # Detail first, status second: the runbook waits on the status value, so it must not see
  # a terminal status before the detail it will read is there.
  aws ssm put-parameter --region "$AWS_REGION" --name "${result_param}/detail" \
    --type String --overwrite \
    --value "$(jq -nc --arg d "$2" --arg dg "$digest" --arg sha "$release_sha" \
      --arg i "$instance_id" --arg at "$(date -u +%FT%TZ)" \
      '{detail: $d, digest: $dg, release_sha: $sha, instance: $i, finished_at: $at}')" \
    >/dev/null || log "WARNING: could not publish the detail to ${result_param}/detail"
  aws ssm put-parameter --region "$AWS_REGION" --name "${result_param}/status" \
    --type String --overwrite --value "$1" \
    >/dev/null || log "WARNING: could not publish the status to ${result_param}/status"
}

finish() { # <ok|failed> <detail> <exit code>
  publish "$1" "$2"
  log "$1: $2 (the runbook terminates this host)"
  trap - ERR EXIT
  exit "$3"
}
fail() { finish failed "$*" 1; }
trap 'fail "the migration job aborted unexpectedly"' ERR
trap 'fail "the migration job was terminated"' EXIT

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "tag app:artifact-digest is not a digest"
[[ "$result_param" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "tag app:result-parameter is not a parameter path"
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]] || fail "tag app:release is not a commit SHA"
subject="${IMAGE_REPOSITORY}@${digest}"
install -d -m 0750 "$RUN_DIR"

identity_regexp="^https://github\.com/${TEMPLATE_REPO//./\\.}/\.github/workflows/build-publish\.yml@"
log "verifying ${subject}"
# Registry credentials go to the private runtime directory, not to $HOME, which
# ProtectHome makes unavailable anyway.
export ORAS_CONFIG="${RUN_DIR}/registry.json"
aws ecr get-login-password --region "$AWS_REGION" |
  oras login --registry-config "$ORAS_CONFIG" --username AWS --password-stdin \
    "${IMAGE_REPOSITORY%%/*}" >/dev/null
cosign verify "$subject" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --certificate-github-workflow-ref refs/heads/main \
  --output json > "${RUN_DIR}/cosign-verify.json"
cosign verify-attestation "$subject" --type https://slsa.dev/provenance/v1 \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --output json > "${RUN_DIR}/provenance.json"

log "pulling and extracting the release"
rm -rf "${RELEASE_DIR}.new" "${RUN_DIR}/pull"
install -d -m 0755 "${RELEASE_DIR}.new" "${RUN_DIR}/pull"
oras pull --registry-config "$ORAS_CONFIG" "$subject" --output "${RUN_DIR}/pull"
bundle="$(find "${RUN_DIR}/pull" -maxdepth 1 -name 'app-*.tar.gz' -print -quit)"
[[ -n "$bundle" ]] || fail "the release carries no application bundle"
/opt/backend/extract-bundle.py --layout app "$bundle" "${RELEASE_DIR}.new" > "${RUN_DIR}/files.txt"
rm -rf "$RELEASE_DIR"
mv "${RELEASE_DIR}.new" "$RELEASE_DIR"

shopt -s nullglob
files=("${RELEASE_DIR}"/migrations/*.sql)
shopt -u nullglob
((${#files[@]} > 0)) || finish ok "the release carries no migrations" 0

db_host='' db_port='' db_name='' db_user=''
while IFS=$'\t' read -r name value; do
  case "${name##*/}" in
    host) db_host="$value" ;;
    port) db_port="$value" ;;
    name) db_name="$value" ;;
    migrator_user) db_user="$value" ;;
  esac
done < <(aws ssm get-parameters-by-path --region "$AWS_REGION" --path "${CONFIG_PARAMETER_PATH}/db" \
  --recursive --query 'Parameters[].[Name,Value]' --output text)
[[ -n "$db_host" && -n "$db_port" && -n "$db_name" && -n "$db_user" ]] ||
  fail "incomplete database configuration under ${CONFIG_PARAMETER_PATH}/db"

# IAM database authentication: a 15-minute token, no stored password anywhere.
PGPASSWORD="$(aws rds generate-db-auth-token --region "$AWS_REGION" \
  --hostname "$db_host" --port "$db_port" --username "$db_user")"
export PGPASSWORD
export PGSSLMODE=verify-full
export PGSSLROOTCERT="${PGSSLROOTCERT:-/etc/backend/rds-ca.pem}"
psql_base=(psql --host "$db_host" --port "$db_port" --dbname "$db_name" --username "$db_user"
  --no-password --no-psqlrc --quiet --set ON_ERROR_STOP=1)
timeouts="SET lock_timeout = '${LOCK_TIMEOUT}'; SET statement_timeout = '${STATEMENT_TIMEOUT}';"

# psql interprets backslash meta-commands in a file, including `\!` which runs a shell
# command, and an explicit BEGIN/COMMIT inside a file would break the all-or-nothing
# guarantee. Migration files come from the release, so both are rejected outright and the
# SQL is then submitted as ONE query string, never with --file.
# The same guard the pipeline runs, baked into the AMI beside the extractor: it refuses psql
# meta-commands (`\!` runs a shell command) and any statement that would divide this job's
# transaction, after removing comments, strings and dollar-quoted bodies.
reject_unsafe() { # reject_unsafe <file>
  local file="$1" out
  if out="$(/opt/backend/sql_guard.py "$file" 2>&1)"; then
    return 0
  fi
  fail "${out:-${file##*/} was refused by the SQL guard}"
}

"${psql_base[@]}" --command "${timeouts}
  CREATE TABLE IF NOT EXISTS schema_migrations (
    filename text PRIMARY KEY,
    sha256 text NOT NULL,
    release_sha text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now());
  ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS sha256 text;" ||
  fail "could not ensure the migration ledger exists"

log "applying up to ${#files[@]} migration file(s) as ${db_user}"
applied=0
skipped=0
for file in "${files[@]}"; do
  base="$(basename "$file")"
  reject_unsafe "$file"
  digest_of_file="$(sha256sum "$file" | cut -d" " -f1)"

  # One transaction per file. The advisory lock serialises concurrent jobs, and the ledger
  # row is inserted BEFORE the file runs: if the file was applied already, the primary key
  # rejects the insert, the transaction aborts and the file's statements never execute.
  sql="${timeouts}
    SELECT pg_advisory_xact_lock(hashtext('schema_migrations'));
    INSERT INTO schema_migrations (filename, sha256, release_sha)
    VALUES (${base@Q}, ${digest_of_file@Q}, ${release_sha@Q});
    $(cat "$file")"

  if out="$("${psql_base[@]}" --command "$sql" 2>&1)"; then
    log "  ${base}: applied"
    applied=$((applied + 1))
    continue
  fi
  # Only the ledger's own primary key means "already applied". A unique violation raised by
  # the migration itself is a failure, and so is a conflict with no ledger row behind it.
  if ! grep -q 'schema_migrations_pkey' <<<"$out"; then
    log "$out"
    fail "migration ${base} failed and was rolled back"
  fi
  if ! recorded="$("${psql_base[@]}" --tuples-only --no-align --set "f=${base}" \
    --command "SELECT sha256 FROM schema_migrations WHERE filename = :'f';" 2>&1)"; then
    log "$recorded"
    fail "could not read the migration ledger after a conflict on ${base}"
  fi
  recorded="${recorded//[[:space:]]/}"
  if [[ -z "$recorded" ]]; then
    log "$out"
    fail "migration ${base} hit the ledger primary key but no ledger row exists; the conflict came from the migration itself"
  fi
  if [[ "$recorded" != "$digest_of_file" ]]; then
    fail "migration ${base} was applied earlier with different content (${recorded})"
  fi
  log "  ${base}: already applied, unchanged"
  skipped=$((skipped + 1))
done

finish ok "applied ${applied}, skipped ${skipped} of ${#files[@]} migration file(s) for ${release_sha}" 0
