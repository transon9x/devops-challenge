#!/usr/bin/env bash
# Static analysis with a digest-pinned Semgrep image and commit-pinned rules, offline.
# Required env: APP_DIR FAIL_ON OUT_DIR RULES_DIR
# Optional env: STACK (node)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tools.env
source "${here}/../tools.env"

: "${APP_DIR:?}"
: "${FAIL_ON:?}"
: "${OUT_DIR:?}"
: "${RULES_DIR:?}"
mkdir -p "$OUT_DIR"

case "$FAIL_ON" in
  high) severity=(--severity ERROR) ;;
  medium) severity=(--severity ERROR --severity WARNING) ;;
  low) severity=(--severity ERROR --severity WARNING --severity INFO) ;;
  *) die "FAIL_ON must be high, medium or low (got '${FAIL_ON}')" ;;
esac

case "${STACK:-node}" in
  node) packs=(javascript) ;;
  python) packs=(python) ;;
  go) packs=(go) ;;
  *) die "unsupported STACK '${STACK}'" ;;
esac
configs=()
for pack in "${packs[@]}"; do
  [[ -d "${RULES_DIR}/${pack}" ]] || die "rule pack ${pack} not found under ${RULES_DIR}"
  configs+=(--config "/rules/${pack}")
done

excludes=()
if [[ -s "${OUT_DIR}/semgrep-exclude.args" ]]; then
  mapfile -t excludes < "${OUT_DIR}/semgrep-exclude.args"
fi

app_abs="$(cd "$APP_DIR" && pwd)"
rules_abs="$(cd "$RULES_DIR" && pwd)"
set +e
docker run --rm --network none \
  -v "${app_abs}:/src:ro" -v "${rules_abs}:/rules:ro" -v "${OUT_DIR}:/out" \
  "semgrep/semgrep:${SEMGREP_VERSION}@${SEMGREP_IMAGE_DIGEST}" \
  semgrep scan "${configs[@]}" "${severity[@]}" "${excludes[@]}" \
  --metrics off --oss-only --disable-version-check --error \
  --sarif --output /out/semgrep.sarif /src
rc=$?
set -e

if [[ -f "${OUT_DIR}/semgrep.sarif" ]]; then
  jq -r '[.runs[].results[]] | group_by(.ruleId) | .[] | "\(length)\t\(.[0].ruleId)"' \
    "${OUT_DIR}/semgrep.sarif" | sort -rn | head -50
fi

case "$rc" in
  0) say "semgrep: no findings at or above the ${FAIL_ON} threshold" ;;
  1) die "semgrep found blocking findings; fix them or add an expiring entry to scan-ignore.yml" ;;
  *) die "semgrep exited ${rc}" ;;
esac
