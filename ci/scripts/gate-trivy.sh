#!/usr/bin/env bash
# Software composition analysis, misconfiguration and licence gate on a source tree.
# Required env: APP_DIR FAIL_ON OUT_DIR
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${APP_DIR:?}"
: "${FAIL_ON:?}"
: "${OUT_DIR:?}"
mkdir -p "$OUT_DIR"

severities="$(severities_for "$FAIL_ON")" || die "FAIL_ON must be critical, high, medium or low"

ignore=()
if [[ -s "${OUT_DIR}/trivyignore.yaml" ]]; then
  ignore=(--ignorefile "${OUT_DIR}/trivyignore.yaml")
fi

say "==> SBOM (CycloneDX)"
trivy fs --quiet --scanners vuln --format cyclonedx --output "${OUT_DIR}/sbom.cdx.json" "$APP_DIR"
say "    $(jq '.components | length' "${OUT_DIR}/sbom.cdx.json") component(s)"

say "==> vulnerabilities, misconfigurations and licences at ${severities}"
set +e
trivy fs --quiet --scanners vuln,misconfig,license --severity "$severities" --exit-code 1 \
  ${ignore[@]+"${ignore[@]}"} --format json --output "${OUT_DIR}/trivy-fs.json" "$APP_DIR"
rc=$?
set -e

jq -r '.Results[]? | "\(.Target)\tvuln=\((.Vulnerabilities // []) | length)\tmisconfig=\((.Misconfigurations // []) | length)\tlicence=\((.Licenses // []) | length)"' \
  "${OUT_DIR}/trivy-fs.json"
jq -r '.Results[]? | .Vulnerabilities[]? | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName)@\(.InstalledVersion)\tfixed: \(.FixedVersion // "-")"' \
  "${OUT_DIR}/trivy-fs.json" | head -50

case "$rc" in
  0) say "trivy: clean at ${severities}" ;;
  1) die "trivy found blocking findings; upgrade the dependency or add an expiring entry to scan-ignore.yml" ;;
  *) die "trivy exited ${rc}" ;;
esac
