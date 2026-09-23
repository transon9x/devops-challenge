#!/usr/bin/env bash
# Production only promotes a digest that dev deployed and smoke-tested. Two proofs:
# the marker the dev role wrote (the prod role cannot write it) and the promotion
# attestation signed by THIS template revision's deploy workflow from the expected
# repository, whose predicate is checked by cosign itself through a CUE policy.
#
# Required env: KIND SUBJECT DIGEST PROMOTION_BUCKET TEMPLATE_REPO TEMPLATE_SHA SOURCE_REPO SOURCE_REF
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${KIND:?}"
: "${SUBJECT:?}"
: "${DIGEST:?}"
: "${PROMOTION_BUCKET:?}"
: "${TEMPLATE_REPO:?}"
: "${TEMPLATE_SHA:?}"
: "${SOURCE_REPO:?}"
: "${SOURCE_REF:?}"
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
require_digest "$DIGEST"
require_sha "$TEMPLATE_SHA"
# The proof field names what dev actually demonstrated for this kind of promotion.
case "$KIND" in
  backend) deploy_workflow=deploy-ec2.yml proof=smoke_test ;;
  frontend) deploy_workflow=deploy-s3.yml proof=smoke_test ;;
  migrate-backend) deploy_workflow=migrate-db.yml proof=migration ;;
  *) die "KIND must be backend, frontend or migrate-backend" ;;
esac

key="$(promotion_key "$KIND" "$DIGEST")"
say "==> marker s3://${PROMOTION_BUCKET}/${key}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set +e
err="$(aws s3api get-object --bucket "$PROMOTION_BUCKET" --key "$key" "${work}/marker.json" 2>&1 >/dev/null)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  code="$(aws_error_code "$err")"
  if [[ "$code" == "NotFound" ]]; then
    die "digest ${DIGEST} has not passed dev; deploy it to dev first"
  fi
  die "could not read the promotion marker (${code}); an access or transport error is not permission to proceed: ${err}"
fi
marker_digest="$(jq -r '.digest // empty' "${work}/marker.json")"
[[ "$marker_digest" == "$DIGEST" ]] || die "marker digest '${marker_digest}' does not match ${DIGEST}"
say "    dev deployed this digest at $(jq -r '.deployed_at' "${work}/marker.json") (run $(jq -r '.run' "${work}/marker.json"))"

identity="https://github.com/${TEMPLATE_REPO}/.github/workflows/${deploy_workflow}@${TEMPLATE_SHA}"
cat > "${work}/promotion.cue" <<EOF
predicateType: "https://schemas.example.com/ci-templates/promotion/v1"
predicate: {
	environment: "dev"
	digest:      "${DIGEST}"
	"${proof}":  "passed"
}
EOF
say "==> promotion attestation signed by ${identity} from ${SOURCE_REPO} (${SOURCE_REF}), predicate checked by policy"
cosign verify-attestation "$SUBJECT" \
  --type "https://schemas.example.com/ci-templates/promotion/v1" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity "$identity" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --certificate-github-workflow-ref "$SOURCE_REF" \
  --policy "${work}/promotion.cue" \
  --output json > "${work}/attestation.json"
say "promotion verified: ${DIGEST} passed dev (${proof})"
