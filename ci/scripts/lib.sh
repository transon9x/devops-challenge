#!/usr/bin/env bash
# Sourced by every script in this directory, never executed.

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  warn "::error::$*"
  exit 1
}

summary_file() { printf '%s' "${GITHUB_STEP_SUMMARY:-/dev/stdout}"; }

template_root() {
  if [[ -n "${TEMPLATE_ROOT:-}" ]]; then
    printf '%s' "$TEMPLATE_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  fi
}

# "owner/repo/.github/workflows/x.yml@ref" -> "owner/repo"
template_repo_from_ref() { printf '%s' "${1%%/.github/*}"; }

severities_for() {
  case "$1" in
    critical) printf 'CRITICAL' ;;
    high) printf 'HIGH,CRITICAL' ;;
    medium) printf 'MEDIUM,HIGH,CRITICAL' ;;
    low) printf 'LOW,MEDIUM,HIGH,CRITICAL' ;;
    *) return 1 ;;
  esac
}

require_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || die "not an OCI digest: '$1'"; }
require_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "not a full lowercase commit SHA: '$1'"; }
require_env_name() { [[ "$1" =~ ^(dev|prod)$ ]] || die "environment must be dev or prod, got '$1'"; }

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# AccessDenied is tested first: some S3 403 bodies also read "Not Found", and
# mistaking a permission problem for a missing object is the dangerous direction.
aws_error_code() {
  if grep -qiE 'AccessDenied|Forbidden|\(403\)' <<<"$1"; then printf 'AccessDenied'; return; fi
  if grep -qiE 'NoSuchBucket' <<<"$1"; then printf 'NoSuchBucket'; return; fi
  if grep -qiE 'NoSuchKey|\(404\)|Not Found' <<<"$1"; then printf 'NotFound'; return; fi
  if grep -qiE 'PreconditionFailed|\(412\)' <<<"$1"; then printf 'Precondition'; return; fi
  printf 'Unknown'
}

content_type_for() {
  case "$1" in
    *.html) printf 'text/html; charset=utf-8' ;;
    *.js | *.mjs) printf 'text/javascript; charset=utf-8' ;;
    *.css) printf 'text/css; charset=utf-8' ;;
    *.json | *.map) printf 'application/json' ;;
    *.svg) printf 'image/svg+xml' ;;
    *.png) printf 'image/png' ;;
    *.jpg | *.jpeg) printf 'image/jpeg' ;;
    *.webp) printf 'image/webp' ;;
    *.woff2) printf 'font/woff2' ;;
    *.woff) printf 'font/woff' ;;
    *.ico) printf 'image/x-icon' ;;
    *.txt) printf 'text/plain; charset=utf-8' ;;
    *) printf 'application/octet-stream' ;;
  esac
}

promotion_key() { printf 'promotions/%s/%s.dev-ok' "$1" "${2#sha256:}"; }
