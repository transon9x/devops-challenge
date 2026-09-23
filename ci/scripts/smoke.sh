#!/usr/bin/env bash
# The site answers, it is HTML, and every asset the served index.html references
# resolves with a plausible content type. That last check catches a half-published
# release and a distribution that rewrites missing files to index.html.
#
# Required env: SITE_URL
# Optional env: EXPECT_VERSION ATTEMPTS
set -Eeuo pipefail

: "${SITE_URL:?}"
ATTEMPTS="${ATTEMPTS:-5}"
base="${SITE_URL%/}"
body=""
tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

http_get() {
  local url="$1" out="$2" code rc
  set +e
  code="$(curl -sS -o "$out" -w '%{http_code}' -m 15 "$url")"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then printf '000'; else printf '%s' "$code"; fi
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  code="$(http_get "$base/" "$tmp_body")"
  if [[ "$code" == "200" ]]; then
    body="$(cat "$tmp_body")"
    break
  fi
  printf 'attempt %s/%s: got HTTP %s, retrying\n' "$attempt" "$ATTEMPTS" "$code"
  sleep 5
done

[[ -n "$body" ]] || { printf '::error::%s did not return 200\n' "$base"; exit 1; }
grep -qi '<html' <<<"$body" || { printf '::error::%s did not return HTML\n' "$base"; exit 1; }
if [[ -n "${EXPECT_VERSION:-}" ]] && ! grep -q "$EXPECT_VERSION" <<<"$body"; then
  printf '::error::served index.html does not advertise version %s\n' "$EXPECT_VERSION"
  exit 1
fi

mapfile -t assets < <(grep -oE '(src|href)="[^"]*assets/[^"]+"' <<<"$body" \
  | sed -E 's/.*"(.*)"/\1/' | sort -u)
[[ ${#assets[@]} -gt 0 ]] || { printf '::error::served index.html references no assets\n'; exit 1; }

asset_content_type() {
  local url="$1" rc out
  set +e
  out="$(curl -sS -o /dev/null -m 15 -w '%{http_code} %{content_type}' "$url")"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then printf '000 none'; else printf '%s' "$out"; fi
}

for asset in "${assets[@]}"; do
  url="$base/${asset#/}"
  read -r code ctype <<<"$(asset_content_type "$url")"
  [[ "$code" == "200" ]] || { printf '::error::asset %s returned HTTP %s\n' "$url" "$code"; exit 1; }
  case "$asset" in
    *.js) want='javascript' ;;
    *.css) want='css' ;;
    *) want='' ;;
  esac
  if [[ -n "$want" ]] && ! grep -qi "$want" <<<"$ctype"; then
    printf '::error::asset %s returned 200 with content-type %s (expected %s)\n' "$asset" "$ctype" "$want"
    exit 1
  fi
  printf 'asset ok: %s (%s)\n' "$asset" "$ctype"
done
printf 'smoke test passed: %s serves HTML and %s asset(s) resolve\n' "$base" "${#assets[@]}"
