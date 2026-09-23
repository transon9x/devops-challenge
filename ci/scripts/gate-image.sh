#!/usr/bin/env bash
# Vulnerability and secret gate on a pushed container image, plus its SBOM.
# Required env: IMAGE_REF FAIL_ON OUT_DIR
# Optional: OUT_DIR/trivyignore.yaml (from scan_ignore.py; expired entries already dropped)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${IMAGE_REF:?}"
: "${FAIL_ON:?}"
: "${OUT_DIR:?}"
mkdir -p "$OUT_DIR"
severities="$(severities_for "$FAIL_ON")" || die "FAIL_ON must be critical, high, medium or low"

ignore=()
if [[ -s "${OUT_DIR}/trivyignore.yaml" ]]; then
  ignore=(--ignorefile "${OUT_DIR}/trivyignore.yaml")
fi

say "==> image SBOM"
trivy image --quiet --format cyclonedx --output "${OUT_DIR}/sbom-image.cdx.json" "$IMAGE_REF"

say "==> OS and library vulnerabilities at ${severities}"
set +e
trivy image --quiet --scanners vuln --severity "$severities" --exit-code 1 ${ignore[@]+"${ignore[@]}"} \
  --format json --output "${OUT_DIR}/trivy-image.json" "$IMAGE_REF"
vuln_rc=$?
set -e
jq -r '.Results[]? | .Vulnerabilities[]? | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)@\(.InstalledVersion)\tfixed: \(.FixedVersion // "-")"' \
  "${OUT_DIR}/trivy-image.json" | head -50

say "==> secrets baked into any layer (every severity blocks, never suppressed)"
set +e
trivy image --quiet --scanners secret --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 1 \
  --format json --output "${OUT_DIR}/trivy-image-secrets.json" "$IMAGE_REF"
secret_rc=$?
set -e
# The raw report would otherwise contain the matched secret itself.
jq 'del(.Results[]?.Secrets[]?.Match, .Results[]?.Secrets[]?.Code)' "${OUT_DIR}/trivy-image-secrets.json" \
  > "${OUT_DIR}/trivy-image-secrets.redacted.json"
rm -f "${OUT_DIR}/trivy-image-secrets.json"
jq -r '.Results[]? | .Secrets[]? | "  \(.Severity)\t\(.RuleID)\t\(.Title)"' "${OUT_DIR}/trivy-image-secrets.redacted.json"

[[ $vuln_rc -eq 0 ]] || die "the image has vulnerabilities at or above ${FAIL_ON}; upgrade, or add an expiring entry to scan-ignore.yml"
[[ $secret_rc -eq 0 ]] || die "the image contains a secret; rebuild with a BuildKit --secret mount or a runtime secret instead of COPY"
say "image gate passed for ${IMAGE_REF}"
