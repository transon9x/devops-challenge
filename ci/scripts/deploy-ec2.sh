#!/usr/bin/env bash
# Immutable EC2 rollout of one image digest through the version-pinned Automation runbook.
#
# Order: verify signature + provenance → (prod) require the dev promotion → start the
# runbook (new launch-template version, instance refresh with auto-rollback) → poll to a
# terminal state → smoke test → (dev) record the promotion.
#
# Required env: ARTIFACT DIGEST RELEASE_SHA ENVIRONMENT PROMOTION_BUCKET TEMPLATE_REPO TEMPLATE_SHA
#               SOURCE_REPO SOURCE_REF SSM_DOCUMENT_ARN SSM_DOCUMENT_VERSION AUTOMATION_ROLE_ARN
#               ASG_NAME LAUNCH_TEMPLATE_ID BACKEND_URL
# Optional env: ALARM_NAMES (comma-separated) CHECKPOINTS (comma-separated) DRY_RUN
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${ARTIFACT:?}" "${DIGEST:?}" "${RELEASE_SHA:?}" "${ENVIRONMENT:?}" "${PROMOTION_BUCKET:?}"
: "${TEMPLATE_REPO:?}" "${TEMPLATE_SHA:?}" "${SOURCE_REPO:?}" "${SOURCE_REF:?}"
: "${SSM_DOCUMENT_ARN:?}" "${SSM_DOCUMENT_VERSION:?}" "${AUTOMATION_ROLE_ARN:?}"
: "${ASG_NAME:?}" "${LAUNCH_TEMPLATE_ID:?}" "${BACKEND_URL:?}"
require_digest "$DIGEST"
require_sha "$RELEASE_SHA"
require_env_name "$ENVIRONMENT"
[[ "$SSM_DOCUMENT_VERSION" =~ ^[0-9]+$ ]] || die "SSM_DOCUMENT_VERSION must be a numbered document version, got '${SSM_DOCUMENT_VERSION}'"
DRY_RUN="${DRY_RUN:-false}"
SUBJECT="${ARTIFACT}@${DIGEST}"
SUMMARY="$(summary_file)"
POLL_DEADLINE_S="${POLL_DEADLINE_S:-7200}"

marker_key="$(promotion_key backend "$DIGEST")"
params="$(jq -n \
  --arg role "$AUTOMATION_ROLE_ARN" --arg env "$ENVIRONMENT" --arg asg "$ASG_NAME" \
  --arg lt "$LAUNCH_TEMPLATE_ID" --arg digest "$DIGEST" --arg bucket "$PROMOTION_BUCKET" \
  --arg marker "$([[ "$ENVIRONMENT" == "prod" ]] && printf '%s' "$marker_key")" \
  --arg desc "${ENVIRONMENT} ${RELEASE_SHA} run ${GITHUB_RUN_ID:-local}" \
  --arg alarms "${ALARM_NAMES:-}" --arg checkpoints "${CHECKPOINTS:-}" \
  '{AutomationAssumeRole: [$role], Environment: [$env], AutoScalingGroupName: [$asg],
    LaunchTemplateId: [$lt], ArtifactDigest: [$digest], PromotionBucket: [$bucket],
    PromotionMarkerKey: [$marker], ReleaseDescription: [$desc],
    AlarmNames: ($alarms | split(",") | map(select(length > 0))),
    CheckpointPercentages: ($checkpoints | split(",") | map(select(length > 0)))}')"

if [[ "$DRY_RUN" == "true" ]]; then
  {
    say "### DRY RUN — nothing was deployed to ${ENVIRONMENT}"
    say ""
    say "No OIDC token was requested and no AWS API was called."
    say ""
    say '```'
    say "cosign verify ${SUBJECT} … && gh attestation verify oci://${SUBJECT} …"
    [[ "$ENVIRONMENT" == "prod" ]] && say "aws s3api get-object --bucket ${PROMOTION_BUCKET} --key ${marker_key}"
    say "aws ssm start-automation-execution --document-name ${SSM_DOCUMENT_ARN} \\"
    say "  --document-version ${SSM_DOCUMENT_VERSION} --parameters '${params}'"
    say "# the runbook: stable LT version resolved at execution -> new version with ONLY tag"
    say "#   app:artifact-digest=${DIGEST} changed -> instance refresh on ${ASG_NAME}"
    say "#   (MinHealthy 100 %, AutoRollback, alarms: ${ALARM_NAMES:-none}, checkpoints: ${CHECKPOINTS:-none})"
    say "# poll to Successful | Failed | RollbackSuccessful | RollbackFailed; verify every InService instance"
    say "# runs the new version (a digest that is already current skips the refresh); smoke test ${BACKEND_URL}/health"
    say '```'
  } >> "$SUMMARY"
  say "DRY RUN: no AWS calls were made."
  exit 0
fi

SUBJECT="$SUBJECT" TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" \
  SOURCE_REPO="$SOURCE_REPO" SOURCE_SHA="$RELEASE_SHA" SOURCE_REF="$SOURCE_REF" \
  "${here}/verify-release.sh"

if [[ "$ENVIRONMENT" == "prod" ]]; then
  KIND=backend SUBJECT="$SUBJECT" DIGEST="$DIGEST" PROMOTION_BUCKET="$PROMOTION_BUCKET" \
    TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" SOURCE_REPO="$SOURCE_REPO" SOURCE_REF="$SOURCE_REF" \
    "${here}/require-promotion.sh"
fi

say "==> starting the deploy runbook ${SSM_DOCUMENT_ARN} (version ${SSM_DOCUMENT_VERSION})"
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
refresh_id="$(jq -r '."StartInstanceRefresh.InstanceRefreshId"[0] // "-"' <<<"$outputs")"
new_version="$(jq -r '."PrepareLaunchTemplateVersion.NewVersion"[0] // "-"' <<<"$outputs")"
prev_version="$(jq -r '."PrepareLaunchTemplateVersion.PreviousVersion"[0] // "-"' <<<"$outputs")"
refresh_status="$(jq -r '."ReadOutcome.Status"[0] // "-"' <<<"$outputs")"
already_current="$(jq -r '."PrepareLaunchTemplateVersion.AlreadyCurrent"[0] // "false"' <<<"$outputs")"
fleet_count="$(jq -r '."VerifyFleet.InstancesOnNewVersion"[0] // "-"' <<<"$outputs")"
refresh_reason="$(jq -r '."ReadOutcome.StatusReason"[0] // "-"' <<<"$outputs")"
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
    say "| launch template | \`${LAUNCH_TEMPLATE_ID}\` version \`${prev_version}\` → \`${new_version}\` |"
    say "| instance refresh | \`${refresh_id}\` (\`${refresh_status}\`) |"
    say "| already current | \`${already_current}\` |"
    say "| InService instances on the new version | \`${fleet_count}\` |"
    [[ -n "$failure" ]] && say "| failure | ${failure} |"
    [[ "$refresh_reason" != "-" && -n "$refresh_reason" ]] && say "| refresh reason | ${refresh_reason} |"
  } >> "$SUMMARY"
}

case "$status" in
  Success | CompletedWithSuccess) ;;
  Unknown)
    report "${ENVIRONMENT} deploy status could not be determined"
    die "could not read execution ${execution_id}; do not assume it failed and do not re-run blindly"
    ;;
  *)
    case "$refresh_status" in
      RollbackSuccessful) report "${ENVIRONMENT} deploy FAILED — rolled back to launch-template version ${prev_version}" ;;
      RollbackFailed) report "${ENVIRONMENT} deploy FAILED and the ROLLBACK FAILED — page the on-call" ;;
      *) report "${ENVIRONMENT} deploy FAILED before or during the instance refresh" ;;
    esac
    die "execution ${execution_id} ended ${status} (refresh ${refresh_status}): ${failure:-$refresh_reason}"
    ;;
esac

say "==> smoke testing ${BACKEND_URL}/health for version ${RELEASE_SHA}"
ok=false
for attempt in $(seq 1 10); do
  if body="$(curl -fsS -m 10 "${BACKEND_URL%/}/health" 2>/dev/null)" && jq -e --arg v "$RELEASE_SHA" \
    '.status == "ok" and .version == $v' <<<"$body" >/dev/null 2>&1; then
    ok=true
    break
  fi
  say "    attempt ${attempt}/10: not yet serving ${RELEASE_SHA}"
  sleep 15
done
if [[ "$ok" != "true" ]]; then
  report "${ENVIRONMENT} refresh succeeded but the smoke test FAILED"
  die "the fleet is not serving ${RELEASE_SHA}; roll back by redeploying the previous release"
fi

report "Deployed to ${ENVIRONMENT}"
if [[ "$ENVIRONMENT" == "dev" ]]; then
  KIND=backend SUBJECT="$SUBJECT" DIGEST="$DIGEST" RELEASE_SHA="$RELEASE_SHA" \
    PROMOTION_BUCKET="$PROMOTION_BUCKET" ENVIRONMENT=dev \
    DETAIL="automation:${execution_id} refresh:${refresh_id} lt:${LAUNCH_TEMPLATE_ID}/${new_version}" \
    "${here}/record-promotion.sh"
fi
