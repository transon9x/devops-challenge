#!/usr/bin/env bash
# Required env: SOURCE_DIR OUT_DIR
# Optional env: GITLEAKS_LOG_OPTS (e.g. "<base>..<head>" to scan only a pull request's commits)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"

: "${SOURCE_DIR:?}"
: "${OUT_DIR:?}"
mkdir -p "$OUT_DIR"

args=(git --no-banner --redact --exit-code 2
  --report-format sarif --report-path "${OUT_DIR}/gitleaks.sarif")
if [[ -n "${GITLEAKS_LOG_OPTS:-}" ]]; then
  args+=(--log-opts "$GITLEAKS_LOG_OPTS")
fi

set +e
gitleaks "${args[@]}" "$SOURCE_DIR"
rc=$?
set -e

case "$rc" in
  0) say "gitleaks: no secrets found" ;;
  2)
    count="$(jq '[.runs[].results[]] | length' "${OUT_DIR}/gitleaks.sarif" 2>/dev/null || echo '?')"
    die "gitleaks found ${count} secret(s). Rotate the credential first, then remove it from history; a false positive is documented in .gitleaksignore with the fingerprint and a reason"
    ;;
  *) die "gitleaks exited ${rc}" ;;
esac
