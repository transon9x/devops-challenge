#!/usr/bin/env bash
# usage: install-tool.sh <gitleaks|trivy|cosign|oras|hadolint> [dest_dir]
# Downloads the release pinned in ci/tools.env, verifies its SHA-256, installs it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "${here}/lib.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../tools.env
source "${here}/../tools.env"

tool="${1:?usage: install-tool.sh <tool> [dest_dir]}"
dest="${2:-${RUNNER_TEMP:-/tmp}/ci-tools/bin}"
gh="https://github.com"

case "$tool" in
  gitleaks)
    url="${gh}/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    sum="$GITLEAKS_SHA256" kind=tgz bin=gitleaks ;;
  trivy)
    url="${gh}/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
    sum="$TRIVY_SHA256" kind=tgz bin=trivy ;;
  cosign)
    url="${gh}/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
    sum="$COSIGN_SHA256" kind=bin bin=cosign ;;
  oras)
    url="${gh}/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    sum="$ORAS_SHA256" kind=tgz bin=oras ;;
  hadolint)
    url="${gh}/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64"
    sum="$HADOLINT_SHA256" kind=bin bin=hadolint ;;
  *) die "unknown tool '${tool}'" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

curl -fsSL --retry 3 --retry-delay 2 -o "${work}/download" "$url"
actual="$(sha256_file "${work}/download")"
[[ "$actual" == "$sum" ]] || die "${tool}: checksum mismatch (expected ${sum}, got ${actual})"

if [[ "$kind" == "tgz" ]]; then
  tar -xzf "${work}/download" -C "$work" "$bin"
  install -m 0755 "${work}/${bin}" "${dest}/${bin}"
else
  install -m 0755 "${work}/download" "${dest}/${bin}"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$dest" >> "$GITHUB_PATH"
fi
say "installed ${bin} from ${url##*/} into ${dest}"
