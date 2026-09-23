#!/usr/bin/env bash
# Ask for the database migrations of one verified release to be applied, as a job on an
# ephemeral EC2 host, through the version-pinned Automation runbook.
#
# Order: verify signature + provenance → (prod) require the dev migration → start the
# runbook (snapshot, job host, await its published result, terminate) → poll to a terminal
# state → (dev) record the migration.
#
# This script never connects to the database and holds no database credentials.
#
# Required env: ARTIFACT DIGEST RELEASE_SHA ENVIRONMENT PROMOTION_BUCKET TEMPLATE_REPO
#               TEMPLATE_SHA SOURCE_REPO SOURCE_REF SSM_DOCUMENT_ARN SSM_DOCUMENT_VERSION
#               AUTOMATION_ROLE_ARN MIGRATION_LAUNCH_TEMPLATE_ID
#               MIGRATION_LAUNCH_TEMPLATE_VERSION DB_CLUSTER_IDENTIFIER
#               RESULT_PARAMETER_PREFIX
# Optional env: DRY_RUN
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${ARTIFACT:?}" "${DIGEST:?}" "${RELEASE_SHA:?}" "${ENVIRONMENT:?}" "${PROMOTION_BUCKET:?}"
: "${TEMPLATE_REPO:?}" "${TEMPLATE_SHA:?}" "${SOURCE_REPO:?}" "${SOURCE_REF:?}"
: "${SSM_DOCUMENT_ARN:?}" "${SSM_DOCUMENT_VERSION:?}" "${AUTOMATION_ROLE_ARN:?}"
: "${MIGRATION_LAUNCH_TEMPLATE_ID:?}" "${MIGRATION_LAUNCH_TEMPLATE_VERSION:?}"
: "${DB_CLUSTER_IDENTIFIER:?}" "${RESULT_PARAMETER_PREFIX:?}"
require_digest "$DIGEST"
require_sha "$RELEASE_SHA"
require_env_name "$ENVIRONMENT"
[[ "$SSM_DOCUMENT_VERSION" =~ ^[0-9]+$ ]] || die "SSM_DOCUMENT_VERSION must be a numbered document version, got '${SSM_DOCUMENT_VERSION}'"
[[ "$MIGRATION_LAUNCH_TEMPLATE_VERSION" =~ ^[0-9]+$ ]] || die "the migration launch-template version must be a number, not \$Latest or \$Default"
DRY_RUN="${DRY_RUN:-false}"
SUBJECT="${ARTIFACT}@${DIGEST}"
SUMMARY="$(summary_file)"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-5400}"
PROMOTION_KIND=migrate-backend

marker_key="$(promotion_key "$PROMOTION_KIND" "$DIGEST")"
params="$(jq -n \
  --arg role "$AUTOMATION_ROLE_ARN" --arg env "$ENVIRONMENT" --arg digest "$DIGEST" \
  --arg sha "$RELEASE_SHA" --arg lt "$MIGRATION_LAUNCH_TEMPLATE_ID" \
  --arg ltv "$MIGRATION_LAUNCH_TEMPLATE_VERSION" --arg cluster "$DB_CLUSTER_IDENTIFIER" \
  --arg prefix "${RESULT_PARAMETER_PREFIX%/}" \
  --arg desc "${ENVIRONMENT} ${RELEASE_SHA} run ${GITHUB_RUN_ID:-local}" \
  '{AutomationAssumeRole: [$role], Environment: [$env], ArtifactDigest: [$digest],
    ReleaseSha: [$sha], LaunchTemplateId: [$lt], LaunchTemplateVersion: [$ltv],
    DBClusterIdentifier: [$cluster], ResultParameterPrefix: [$prefix],
    ReleaseDescription: [$desc]}')"

if [[ "$DRY_RUN" == "true" ]]; then
  {
    say "### DRY RUN — no migration ran against ${ENVIRONMENT}"
    say ""
    say "No OIDC token was requested and no AWS API was called."
    say ""
    say '```'
    say "cosign verify ${SUBJECT} … && gh attestation verify oci://${SUBJECT} …"
    [[ "$ENVIRONMENT" == "prod" ]] && say "aws s3api get-object --bucket ${PROMOTION_BUCKET} --key ${marker_key}"
    say "aws ssm start-automation-execution --document-name ${SSM_DOCUMENT_ARN} \\"
    say "  --document-version ${SSM_DOCUMENT_VERSION} --parameters '${params}'"
    say "# the runbook: snapshot ${DB_CLUSTER_IDENTIFIER} -> launch one job host from"
    say "#   ${MIGRATION_LAUNCH_TEMPLATE_ID} version ${MIGRATION_LAUNCH_TEMPLATE_VERSION} tagged with the digest"
    say "#   -> the host verifies the release, applies migrations/*.sql in one transaction each"
    say "#   -> publishes <prefix>/${RELEASE_SHA}/<execution id>/{detail,status}"
    say "#   -> the runbook checks the digest, release and instance match, then terminates by tag"
    say '```'
  } >> "$SUMMARY"
  say "DRY RUN: no AWS calls were made."
  exit 0
fi

SUBJECT="$SUBJECT" TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" \
  SOURCE_REPO="$SOURCE_REPO" SOURCE_SHA="$RELEASE_SHA" SOURCE_REF="$SOURCE_REF" \
  "${here}/verify-release.sh"

if [[ "$ENVIRONMENT" == "prod" ]]; then
  KIND="$PROMOTION_KIND" SUBJECT="$SUBJECT" DIGEST="$DIGEST" PROMOTION_BUCKET="$PROMOTION_BUCKET" \
    TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" SOURCE_REPO="$SOURCE_REPO" SOURCE_REF="$SOURCE_REF" \
    "${here}/require-promotion.sh"
fi

say "==> starting the migration runbook ${SSM_DOCUMENT_ARN} (version ${SSM_DOCUMENT_VERSION})"
execution_id="$(aws ssm start-automation-execution \
  --document-name "$SSM_DOCUMENT_ARN" --document-version "$SSM_DOCUMENT_VERSION" \
  --parameters "$params" --query 'AutomationExecutionId' --output text)"
say "    execution ${execution_id}"

status="Unknown"
deadline=$((SECONDS + POLL_DEADLINE_S))
unknown=0
while ((SECONDS < deadline)); do
  if out="$(aws ssm get-automation-execution --automation-execution-id "$execution_id" \
    --query 'AutomationExecution.AutomationExecutionStatus' --output text 2>/dev/null)" && [[ -n "$out" ]]; then
    status="$out"
    unknown=0
  else
    unknown=$((unknown + 1))
    ((unknown < 5)) || { status="Unknown"; break; }
  fi
  case "$status" in
    Success | Failed | TimedOut | Cancelled | CompletedWithFailure | CompletedWithSuccess) break ;;
  esac
  sleep 20
done

execution="$(aws ssm get-automation-execution --automation-execution-id "$execution_id" 2>/dev/null || echo '{}')"
outputs="$(jq -c '.AutomationExecution.Outputs // {}' <<<"$execution")"
snapshot="$(jq -r '."SnapshotCluster.SnapshotIdentifier"[0] // "-"' <<<"$outputs")"
job_host="$(jq -r '."LaunchJobHost.InstanceId"[0] // "-"' <<<"$outputs")"
result_status="$(jq -r '."ReadOutcome.Status"[0] // "-"' <<<"$outputs")"
result_detail="$(jq -r '."ReadOutcome.Detail"[0] // "-"' <<<"$outputs")"
failure="$(jq -r '.AutomationExecution.FailureMessage // ""' <<<"$execution")"

report() {
  {
    say "### ${1}"
    say ""
    say "| field | value |"
    say "|---|---|"
    say "| release | \`${RELEASE_SHA}\` |"
    say "| artifact | \`${SUBJECT}\` |"
    say "| automation execution | \`${execution_id}\` (\`${status}\`) |"
    say "| pre-migration snapshot | \`${snapshot}\` |"
    say "| job host | \`${job_host}\` |"
    say "| migration result | \`${result_status}\` ${result_detail} |"
    [[ -n "$failure" ]] && say "| failure | ${failure} |"
  } >> "$SUMMARY"
}

case "$status" in
  Success | CompletedWithSuccess) ;;
  Unknown)
    report "${ENVIRONMENT} migration status could not be determined"
    die "could not read execution ${execution_id}; the job is idempotent, but check the ledger before re-running"
    ;;
  *)
    report "${ENVIRONMENT} migration FAILED"
    die "execution ${execution_id} ended ${status}: ${failure:-$result_detail}. Each file applies in its own transaction, so a failed file left nothing behind; snapshot ${snapshot} is the restore point if a later file needs reverting"
    ;;
esac

report "Migrated ${ENVIRONMENT}"
if [[ "$ENVIRONMENT" == "dev" ]]; then
  KIND="$PROMOTION_KIND" SUBJECT="$SUBJECT" DIGEST="$DIGEST" RELEASE_SHA="$RELEASE_SHA" \
    PROMOTION_BUCKET="$PROMOTION_BUCKET" ENVIRONMENT=dev \
    DETAIL="automation:${execution_id} snapshot:${snapshot} result:${result_detail}" \
    "${here}/record-promotion.sh"
fi
