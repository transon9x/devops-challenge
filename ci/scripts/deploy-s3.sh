#!/usr/bin/env bash
# Promote a verified frontend bundle (an OCI artifact, by digest) into a site bucket.
#
# Order: verify signature + provenance → (prod) require the dev promotion → pull by
# digest → extract into an empty dir with an allowlist → record the live index.html
# version → arm the rollback trap → upload assets, then config.json, then index.html
# → invalidate → smoke test → disarm → (dev) record the promotion.
#
# Required env: ARTIFACT DIGEST RELEASE_SHA ENVIRONMENT SITE_BUCKET DISTRIBUTION_ID SITE_URL
#               PROMOTION_BUCKET TEMPLATE_REPO TEMPLATE_SHA SOURCE_REPO SOURCE_REF
# Optional env: RUNTIME_CONFIG_JSON DRY_RUN
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${ARTIFACT:?}" "${DIGEST:?}" "${RELEASE_SHA:?}" "${ENVIRONMENT:?}" "${SITE_BUCKET:?}"
: "${DISTRIBUTION_ID:?}" "${SITE_URL:?}" "${PROMOTION_BUCKET:?}" "${TEMPLATE_REPO:?}"
: "${TEMPLATE_SHA:?}" "${SOURCE_REPO:?}" "${SOURCE_REF:?}"
require_digest "$DIGEST"
require_sha "$RELEASE_SHA"
require_env_name "$ENVIRONMENT"
DRY_RUN="${DRY_RUN:-false}"
SUBJECT="${ARTIFACT}@${DIGEST}"
SUMMARY="$(summary_file)"

if [[ "$DRY_RUN" == "true" ]]; then
  {
    say "### DRY RUN — nothing was deployed to ${ENVIRONMENT}"
    say ""
    say '```'
    say "cosign verify ${SUBJECT} … && gh attestation verify oci://${SUBJECT} …"
    [[ "$ENVIRONMENT" == "prod" ]] && say "aws s3api get-object --bucket ${PROMOTION_BUCKET} --key $(promotion_key frontend "$DIGEST")"
    say "oras pull ${SUBJECT}   # then extract with an allowlist, verify sha256 of every file"
    say "aws s3api put-object --bucket ${SITE_BUCKET} --key assets/…   # immutable cache, content type per file"
    say "aws s3api put-object --bucket ${SITE_BUCKET} --key index.html  # last, no-cache"
    say "aws cloudfront create-invalidation --distribution-id ${DISTRIBUTION_ID} --paths / /index.html /config.json"
    say "# smoke test for ${RELEASE_SHA}; on failure restore the recorded index.html version"
    say '```'
  } >> "$SUMMARY"
  say "DRY RUN: no AWS calls were made."
  exit 0
fi

work="$(mktemp -d)"
ROLLBACK_GUARD="$(mktemp -u)"
cleanup() { rm -rf "$work" "$ROLLBACK_GUARD"; }
trap cleanup EXIT

SUBJECT="$SUBJECT" TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" \
  SOURCE_REPO="$SOURCE_REPO" SOURCE_SHA="$RELEASE_SHA" SOURCE_REF="$SOURCE_REF" \
  "${here}/verify-release.sh"

if [[ "$ENVIRONMENT" == "prod" ]]; then
  KIND=frontend SUBJECT="$SUBJECT" DIGEST="$DIGEST" PROMOTION_BUCKET="$PROMOTION_BUCKET" \
    TEMPLATE_REPO="$TEMPLATE_REPO" TEMPLATE_SHA="$TEMPLATE_SHA" SOURCE_REPO="$SOURCE_REPO" SOURCE_REF="$SOURCE_REF" \
    "${here}/require-promotion.sh"
fi

say "==> pulling ${SUBJECT}"
mkdir -p "${work}/pull" "${work}/dist"
oras pull "$SUBJECT" -o "${work}/pull" >/dev/null
bundle="$(find "${work}/pull" -maxdepth 1 -type f -name '*.tar.gz' | head -n 1)"
[[ -n "$bundle" ]] || die "the artifact contains no .tar.gz layer"
say "==> extracting with the allowlist"
python3 "${here}/extract-bundle.py" "$bundle" "${work}/dist" > "${work}/files.sha256"
file_count="$(grep -c . "${work}/files.sha256")"
say "    ${file_count} file(s)"

say "==> reading the currently live index.html and config.json (the rollback targets)"
set +e
head_err="$(aws s3api head-object --bucket "$SITE_BUCKET" --key index.html 2>&1 >/dev/null)"
head_rc=$?
config_err="$(aws s3api head-object --bucket "$SITE_BUCKET" --key config.json 2>&1 >/dev/null)"
config_rc=$?
set -e
previous_config_version="None"
if [[ $config_rc -eq 0 ]]; then
  previous_config_version="$(aws s3api head-object --bucket "$SITE_BUCKET" --key config.json --query 'VersionId' --output text)"
else
  [[ "$(aws_error_code "$config_err")" == "NotFound" ]] || die "could not read the current config.json: ${config_err}"
fi
previous_version="None"
previous_app_version=""
if [[ $head_rc -eq 0 ]]; then
  previous_version="$(aws s3api head-object --bucket "$SITE_BUCKET" --key index.html --query 'VersionId' --output text)"
  [[ -n "$previous_version" && "$previous_version" != "None" ]] ||
    die "${SITE_BUCKET} is not versioned; enable versioning so a rollback target exists"
  aws s3api get-object --bucket "$SITE_BUCKET" --key index.html --version-id "$previous_version" \
    "${work}/previous-index.html" >/dev/null
  previous_app_version="$(grep -oE 'name="app-version" content="[^"]+"' "${work}/previous-index.html" |
    sed -E 's/.*content="([^"]+)".*/\1/' || true)"
  say "    rollback target: version ${previous_version}, serving '${previous_app_version:-unknown}'"
else
  code="$(aws_error_code "$head_err")"
  [[ "$code" == "NotFound" ]] || die "could not read the current index.html (${code}): ${head_err}"
  say "    no current index.html (first deploy): automatic rollback will not be possible"
fi

invalidate() {
  aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" \
    --paths '/' '/index.html' '/config.json' --query 'Invalidation.Id' --output text
}

rollback() {
  trap - ERR
  if ! (set -o noclobber; : > "$ROLLBACK_GUARD") 2>/dev/null; then
    return 0
  fi
  set +e
  if [[ "$previous_version" == "None" ]]; then
    {
      say "### ${ENVIRONMENT} deployment FAILED and could not be rolled back"
      say ""
      say "There was no previous index.html version to restore (first deploy)."
    } >> "$SUMMARY"
    say "::error::deployment failed with no rollback target"
    return 0
  fi
  say "==> rolling back index.html to version ${previous_version}"
  aws s3api copy-object --bucket "$SITE_BUCKET" --key index.html \
    --copy-source "${SITE_BUCKET}/index.html?versionId=${previous_version}" \
    --metadata-directive REPLACE --content-type 'text/html; charset=utf-8' \
    --cache-control 'no-cache, must-revalidate' >/dev/null
  restore_rc=$?
  if [[ -n "${RUNTIME_CONFIG_JSON:-}" ]]; then
    if [[ "$previous_config_version" != "None" ]]; then
      say "==> rolling back config.json to version ${previous_config_version}"
      aws s3api copy-object --bucket "$SITE_BUCKET" --key config.json \
        --copy-source "${SITE_BUCKET}/config.json?versionId=${previous_config_version}" \
        --metadata-directive REPLACE --content-type application/json \
        --cache-control 'no-cache, must-revalidate' >/dev/null || restore_rc=1
    else
      say "==> config.json did not exist before this deploy; neutralising it"
      printf '{}\n' > "${work}/empty-config.json"
      aws s3api put-object --bucket "$SITE_BUCKET" --key config.json --body "${work}/empty-config.json" \
        --content-type application/json --cache-control 'no-cache, must-revalidate' >/dev/null || restore_rc=1
    fi
  fi
  rollback_invalidation="$(invalidate)"
  aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$rollback_invalidation"
  rollback_ok="no"
  if [[ $restore_rc -eq 0 ]]; then
    if [[ -n "$previous_app_version" ]]; then
      SITE_URL="$SITE_URL" EXPECT_VERSION="$previous_app_version" "${here}/smoke.sh" && rollback_ok="yes"
    else
      SITE_URL="$SITE_URL" "${here}/smoke.sh" && rollback_ok="unverified"
    fi
  fi
  {
    say "### ${ENVIRONMENT} deployment FAILED — rolled back"
    say ""
    say "| field | value |"
    say "|---|---|"
    say "| release attempted | \`${RELEASE_SHA}\` (\`${DIGEST}\`) |"
    say "| restored index.html version | \`${previous_version}\` |"
    say "| restored config.json version | \`${previous_config_version}\` |"
    say "| restored release advertises | \`${previous_app_version:-unknown}\` |"
    say "| rollback verified | \`${rollback_ok}\` |"
  } >> "$SUMMARY"
  [[ "$rollback_ok" == "yes" ]] || say "::error::the rollback was not verified as serving the previous release — page the on-call"
  return 0
}
trap 'rollback; exit 1' ERR

say "==> uploading assets (immutable cache)"
while read -r digest rel; do
  [[ "$rel" == "index.html" ]] && continue
  aws s3api put-object --bucket "$SITE_BUCKET" --key "$rel" --body "${work}/dist/${rel}" \
    --content-type "$(content_type_for "$rel")" \
    --cache-control 'public, max-age=31536000, immutable' \
    --checksum-sha256 "$(printf '%s' "$digest" | xxd -r -p | base64)" >/dev/null
  say "    ${rel}"
done < "${work}/files.sha256"

if [[ -n "${RUNTIME_CONFIG_JSON:-}" ]]; then
  say "==> writing config.json for ${ENVIRONMENT} (runtime configuration, not baked into the build)"
  jq -e . <<<"$RUNTIME_CONFIG_JSON" > "${work}/config.json" || die "RUNTIME_CONFIG_JSON is not valid JSON"
  aws s3api put-object --bucket "$SITE_BUCKET" --key config.json --body "${work}/config.json" \
    --content-type application/json --cache-control 'no-cache, must-revalidate' >/dev/null
fi

say "==> publishing index.html last"
aws s3api put-object --bucket "$SITE_BUCKET" --key index.html --body "${work}/dist/index.html" \
  --content-type 'text/html; charset=utf-8' --cache-control 'no-cache, must-revalidate' >/dev/null
new_version="$(aws s3api head-object --bucket "$SITE_BUCKET" --key index.html --query 'VersionId' --output text)"

say "==> invalidating"
invalidation_id="$(invalidate)"
aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$invalidation_id"

say "==> smoke testing ${SITE_URL}"
SITE_URL="$SITE_URL" EXPECT_VERSION="$RELEASE_SHA" "${here}/smoke.sh"
trap - ERR

{
  say "### Deployed to ${ENVIRONMENT}"
  say ""
  say "| field | value |"
  say "|---|---|"
  say "| release | \`${RELEASE_SHA}\` |"
  say "| artifact | \`${SUBJECT}\` |"
  say "| files | ${file_count} |"
  say "| index.html version | \`${new_version}\` |"
  say "| previous version (rollback target) | \`${previous_version}\` |"
} >> "$SUMMARY"

if [[ "$ENVIRONMENT" == "dev" ]]; then
  KIND=frontend SUBJECT="$SUBJECT" DIGEST="$DIGEST" RELEASE_SHA="$RELEASE_SHA" \
    PROMOTION_BUCKET="$PROMOTION_BUCKET" ENVIRONMENT=dev \
    DETAIL="site:${SITE_BUCKET} index:${new_version}" "${here}/record-promotion.sh"
fi
