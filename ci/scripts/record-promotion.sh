#!/usr/bin/env bash
# After a successful dev deploy and smoke test: write the IAM-gated marker and
# sign a promotion attestation, both keyed by the artifact DIGEST.
#
# Required env: KIND SUBJECT DIGEST RELEASE_SHA PROMOTION_BUCKET ENVIRONMENT DETAIL
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${KIND:?}"
: "${SUBJECT:?}"
: "${DIGEST:?}"
: "${RELEASE_SHA:?}"
: "${PROMOTION_BUCKET:?}"
: "${ENVIRONMENT:?}"
: "${DETAIL:?}"
require_digest "$DIGEST"
[[ "$ENVIRONMENT" == "dev" ]] || die "only a dev run records a promotion"
case "$KIND" in
  backend | frontend) proof=smoke_test ;;
  migrate-backend) proof=migration ;;
  *) die "KIND must be backend, frontend or migrate-backend" ;;
esac

key="$(promotion_key "$KIND" "$DIGEST")"
predicate="$(mktemp)"
trap 'rm -f "$predicate"' EXIT
jq -n --arg env "$ENVIRONMENT" --arg digest "$DIGEST" --arg sha "$RELEASE_SHA" \
  --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}" \
  --arg detail "$DETAIL" --arg at "$(date -u +%FT%TZ)" --arg proof "$proof" \
  '{environment: $env, digest: $digest, release_sha: $sha, run: $run, detail: $detail,
    deployed_at: $at} + {($proof): "passed"}' \
  > "$predicate"

say "==> marker s3://${PROMOTION_BUCKET}/${key}"
set +e
err="$(aws s3api put-object --bucket "$PROMOTION_BUCKET" --key "$key" --body "$predicate" \
  --content-type application/json --if-none-match '*' 2>&1 >/dev/null)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  if [[ "$(aws_error_code "$err")" == "Precondition" ]]; then
    say "    marker already exists for this digest (an earlier dev deploy of the same release); keeping it"
  else
    die "could not write the promotion marker: ${err}"
  fi
fi

say "==> promotion attestation on ${SUBJECT}"
cosign attest --yes --predicate "$predicate" \
  --type "https://schemas.example.com/ci-templates/promotion/v1" "$SUBJECT"
say "recorded: ${DIGEST} passed ${ENVIRONMENT}"
