#!/usr/bin/env bash
# actionlint 1.7.x validates caller inputs only for "./" calls, so the two composition
# workflows are linted from a "./"-normalised stream of their "$/" self-repository calls.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
actionlint="${ACTIONLINT:-actionlint}"
ignore='property "workflow_(repository|sha|ref|file_path)" is not defined in object type'
composition=(.github/workflows/ci.yml .github/workflows/pipeline.yml)

plain=()
for f in .github/workflows/*.yml src/problem4/.github/workflows/*.yml; do
  [[ " ${composition[*]} " == *" ${f} "* ]] || plain+=("$f")
done
if ((${#plain[@]})); then
  "$actionlint" -ignore "$ignore" "${plain[@]}"
fi

for f in "${composition[@]}"; do
  sed 's#uses: \$/#uses: ./#' "$f" | "$actionlint" -ignore "$ignore" -stdin-filename "$f" -
done
echo "actionlint passed for ${#plain[@]} workflows plus ${composition[*]}"
