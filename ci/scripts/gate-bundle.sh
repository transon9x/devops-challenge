#!/usr/bin/env bash
# Vulnerability, licence and secret gate on the exact tree that will run on the instance.
# A deploy without a container image has no image to scan, so the extracted release
# bundle is scanned instead, at the same severity floor and with the same never-suppressible
# secret rule.
# Required env: BUNDLE_DIR FAIL_ON OUT_DIR
# Optional: OUT_DIR/trivyignore.yaml (from scan_ignore.py; expired entries already dropped)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${BUNDLE_DIR:?}"
: "${FAIL_ON:?}"
: "${OUT_DIR:?}"
[[ -d "$BUNDLE_DIR" ]] || die "BUNDLE_DIR ${BUNDLE_DIR} is not a directory"
mkdir -p "$OUT_DIR"
severities="$(severities_for "$FAIL_ON")" || die "FAIL_ON must be critical, high, medium or low"

ignore=()
if [[ -s "${OUT_DIR}/trivyignore.yaml" ]]; then
  ignore=(--ignorefile "${OUT_DIR}/trivyignore.yaml")
fi

say "==> bundle SBOM (CycloneDX)"
trivy fs --quiet --scanners vuln --format cyclonedx --output "${OUT_DIR}/sbom.cdx.json" "$BUNDLE_DIR"
say "    $(jq '.components | length' "${OUT_DIR}/sbom.cdx.json") component(s)"

say "==> dependency vulnerabilities and licences at ${severities}"
set +e
trivy fs --quiet --scanners vuln,license --severity "$severities" --exit-code 1 ${ignore[@]+"${ignore[@]}"} \
  --format json --output "${OUT_DIR}/trivy-bundle.json" "$BUNDLE_DIR"
vuln_rc=$?
set -e
jq -r '.Results[]? | .Vulnerabilities[]? | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)@\(.InstalledVersion)\tfixed: \(.FixedVersion // "-")"' \
  "${OUT_DIR}/trivy-bundle.json" | head -50

say "==> secrets in the shipped files (every severity blocks, never suppressed)"
set +e
trivy fs --quiet --scanners secret --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 1 \
  --format json --output "${OUT_DIR}/trivy-bundle-secrets.json" "$BUNDLE_DIR"
secret_rc=$?
set -e
# The raw report would otherwise contain the matched secret itself.
jq 'del(.Results[]?.Secrets[]?.Match, .Results[]?.Secrets[]?.Code)' "${OUT_DIR}/trivy-bundle-secrets.json" \
  > "${OUT_DIR}/trivy-bundle-secrets.redacted.json"
rm -f "${OUT_DIR}/trivy-bundle-secrets.json"
jq -r '.Results[]? | .Secrets[]? | "  \(.Severity)\t\(.RuleID)\t\(.Title)"' "${OUT_DIR}/trivy-bundle-secrets.redacted.json"

case "$vuln_rc" in
  0) ;;
  1) die "the bundle has findings at or above ${FAIL_ON}; upgrade, or add an expiring entry to scan-ignore.yml" ;;
  *) die "trivy exited ${vuln_rc} on the vulnerability scan" ;;
esac
case "$secret_rc" in
  0) ;;
  1) die "the bundle contains a secret; read it at runtime from Parameter Store instead of shipping it" ;;
  *) die "trivy exited ${secret_rc} on the secret scan" ;;
esac
say "bundle gate passed for ${BUNDLE_DIR} at ${severities}"
