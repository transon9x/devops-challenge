#!/usr/bin/env bash
# Refuse to deploy anything that was not built by the shared build template from
# the expected repository, commit and branch. Two independent proofs are checked:
# the cosign signature and the GitHub build-provenance attestation.
#
# Required env: SUBJECT (repo@sha256:…) TEMPLATE_REPO TEMPLATE_SHA SOURCE_REPO SOURCE_SHA SOURCE_REF
# Optional env: OIDC_ISSUER GH_TOKEN (needed by gh attestation verify)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${SUBJECT:?}"
: "${TEMPLATE_REPO:?}"
: "${TEMPLATE_SHA:?}"
: "${SOURCE_REPO:?}"
: "${SOURCE_SHA:?}"
: "${SOURCE_REF:?}"
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
require_digest "${SUBJECT#*@}"
require_sha "$SOURCE_SHA"
require_sha "$TEMPLATE_SHA"

build_workflow="${TEMPLATE_REPO}/.github/workflows/build-publish.yml"
identity_regexp="^https://github\.com/${build_workflow//./\\.}@"

say "==> cosign: signature by ${build_workflow}, built from ${SOURCE_REPO}@${SOURCE_SHA} (${SOURCE_REF})"
cosign verify "$SUBJECT" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --certificate-github-workflow-sha "$SOURCE_SHA" \
  --certificate-github-workflow-ref "$SOURCE_REF" \
  --output json > "${RUNNER_TEMP:-/tmp}/cosign-verify.json"
say "    signature verified"

say "==> cosign: SBOM attestation by the same identity"
cosign verify-attestation "$SUBJECT" --type cyclonedx \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --certificate-github-workflow-sha "$SOURCE_SHA" \
  --output json > /dev/null
say "    SBOM attestation verified"

say "==> GitHub attestation: SLSA provenance, exact template commit ${TEMPLATE_SHA}"
gh attestation verify "oci://${SUBJECT}" \
  --repo "$SOURCE_REPO" \
  --signer-workflow "$build_workflow" \
  --signer-digest "$TEMPLATE_SHA" \
  --source-digest "$SOURCE_SHA" \
  --source-ref "$SOURCE_REF" \
  --cert-oidc-issuer "$OIDC_ISSUER" \
  --predicate-type https://slsa.dev/provenance/v1 \
  --format json > "${RUNNER_TEMP:-/tmp}/gh-attestation.json"
say "    provenance verified"

say "release ${SUBJECT} is authentic: built by the shared template at ${TEMPLATE_SHA} from ${SOURCE_REPO}@${SOURCE_SHA}"
