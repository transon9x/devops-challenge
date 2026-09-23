#!/usr/bin/env bash
# Baked into the AMI at /opt/backend/bootstrap.sh and run once per boot by
# backend-bootstrap.service. Nothing here is fetched from S3, GitHub or the registry.
#
# Reads the release digest and the artifact kind from the instance tags the launch template
# sets, verifies the release was built by the shared pipeline, fetches it by digest and
# starts the matching unit:
#   image  -> docker pull, backend.service (container sandbox)
#   bundle -> oras pull and extract, backend-bundle.service (systemd sandbox)
# A failure leaves the instance unhealthy, which is what makes the refresh roll back.
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/backend/bootstrap.env}"
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${IMAGE_REPOSITORY:?}" "${TEMPLATE_REPO:?}" "${SOURCE_REPO:?}" "${CONFIG_PARAMETER_PATH:?}" "${AWS_REGION:?}"
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
RUN_DIR="${RUN_DIR:-/run/backend}"
RELEASES_DIR="${RELEASES_DIR:-/opt/backend/releases}"
CURRENT_LINK="${CURRENT_LINK:-/opt/backend/current}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"
IMDS="http://169.254.169.254/latest"

log() { printf 'backend-bootstrap: %s\n' "$*"; }
fail() {
  printf 'backend-bootstrap: ERROR: %s\n' "$*" >&2
  exit 1
}

token="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' "${IMDS}/api/token")"
imds() { curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "${IMDS}/meta-data/$1"; }

digest="$(imds tags/instance/app:artifact-digest)" || fail "instance tag app:artifact-digest is missing (enable instance metadata tags)"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "tag app:artifact-digest is not a digest: '${digest}'"
# The kind is a property of the fleet's AMI and launch template, not of the release: a
# deploy only ever changes the digest. An untagged fleet is a container fleet.
kind="$(imds tags/instance/app:artifact-kind 2>/dev/null || printf 'image')"
kind="${kind:-image}"
[[ "$kind" =~ ^(image|bundle)$ ]] || fail "tag app:artifact-kind must be image or bundle: '${kind}'"
subject="${IMAGE_REPOSITORY}@${digest}"
unit="backend.service"
[[ "$kind" == "image" ]] || unit="backend-bundle.service"
log "release ${subject} (${kind}, ${unit})"

install -d -m 0750 "$RUN_DIR"
registry="${IMAGE_REPOSITORY%%/*}"
password="$(aws ecr get-login-password --region "$AWS_REGION")"
if [[ "$kind" == "image" ]]; then
  printf '%s' "$password" | docker login --username AWS --password-stdin "$registry" >/dev/null
else
  printf '%s' "$password" | oras login --username AWS --password-stdin "$registry" >/dev/null
fi
unset password

identity_regexp="^https://github\.com/${TEMPLATE_REPO//./\\.}/\.github/workflows/build-publish\.yml@"
log "verifying signature (issuer ${OIDC_ISSUER}, identity ${identity_regexp}, source ${SOURCE_REPO})"
cosign verify "$subject" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --certificate-github-workflow-ref refs/heads/main \
  --output json > "${RUN_DIR}/cosign-verify.json"
cosign verify-attestation "$subject" --type https://slsa.dev/provenance/v1 \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --certificate-identity-regexp "$identity_regexp" \
  --certificate-github-workflow-repository "$SOURCE_REPO" \
  --output json > "${RUN_DIR}/provenance.json"

if [[ "$kind" == "image" ]]; then
  log "pulling the image by digest"
  docker pull --quiet "$subject" >/dev/null
  docker image inspect --format '{{join .RepoDigests "\n"}}' "$subject" | grep -qxF "$subject" ||
    fail "pulled image does not carry digest ${digest}"
  printf 'IMAGE_REF=%s\n' "$subject" > "${RUN_DIR}/image"
else
  log "pulling and extracting the bundle by digest"
  # The revision travels with the artifact as an OCI annotation the publish job set, so the
  # running process reports the release it actually is, which the deploy smoke test checks.
  revision="$(oras manifest fetch "$subject" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("annotations", {}).get("org.opencontainers.image.revision", ""))')"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "the artifact carries no org.opencontainers.image.revision annotation"

  # Immutable release directories plus an atomically swapped symlink: an interrupted
  # bootstrap can never leave the instance with no runnable release.
  release="${RELEASES_DIR}/${digest#sha256:}"
  install -d -m 0755 "$RELEASES_DIR"
  if [[ -f "${release}/package.json" ]]; then
    # This digest is already extracted, from an earlier boot or a rollback. Nothing is
    # deleted and nothing is re-extracted: the symlink below just points at it again.
    log "release ${digest} is already on disk"
  else
    rm -rf "${release}.partial" "${RUN_DIR}/pull"
    install -d -m 0755 "${release}.partial"
    install -d -m 0750 "${RUN_DIR}/pull"
    oras pull "$subject" --output "${RUN_DIR}/pull"
    bundle="$(find "${RUN_DIR}/pull" -maxdepth 1 -name 'app-*.tar.gz' -print -quit)"
    [[ -n "$bundle" ]] || fail "the release carries no application bundle"
    # The allowlist is the same extractor the deploy uses: plain files at known paths only.
    /opt/backend/extract-bundle.py --layout app "$bundle" "${release}.partial" > "${RUN_DIR}/files.txt"
    chown -R root:root "${release}.partial"
    # The target does not exist in this branch, so nothing runnable is ever removed first.
    mv "${release}.partial" "$release"
  fi
  ln -sfn "$release" "${CURRENT_LINK}.new"
  mv -T "${CURRENT_LINK}.new" "$CURRENT_LINK"
  printf 'APP_VERSION=%s\nARTIFACT_REF=%s\n' "$revision" "$subject" > "${RUN_DIR}/release"
  # Keep a couple of previous releases so a rollback does not need the registry.
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
    sort -rn | tail -n "+$((KEEP_RELEASES + 1))" | cut -d' ' -f2- |
    while read -r old; do [[ "$old" == "$(readlink -f "$CURRENT_LINK")" ]] || rm -rf "$old"; done
fi

log "runtime configuration from ${CONFIG_PARAMETER_PATH}"
aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$CONFIG_PARAMETER_PATH" \
  --with-decryption --recursive --query 'Parameters[].[Name,Value]' --output text |
  awk -F'\t' -v p="$CONFIG_PARAMETER_PATH" '{ n=$1; sub("^" p "/?", "", n); gsub("/", "_", n); print toupper(n) "=" $2 }' \
  > "${RUN_DIR}/env"
# The release's own version wins over anything in Parameter Store.
[[ "$kind" == "image" ]] || cat "${RUN_DIR}/release" >> "${RUN_DIR}/env"
chmod 0600 "${RUN_DIR}/env"

systemctl reset-failed "$unit" 2>/dev/null || true
systemctl restart "$unit"

port="$(grep -E '^PORT=' "${RUN_DIR}/env" | cut -d= -f2 || true)"
port="${port:-3000}"
for attempt in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:${port}/health" | grep -q '"status":"ok"'; then
    log "healthy after ${attempt} attempt(s); serving ${digest}"
    exit 0
  fi
  sleep 2
done
fail "backend never became healthy"
