#!/usr/bin/env bash
# Prove that rotating NGINX's logs makes NGINX reopen them, which `logrotate -d` cannot show:
# a dry run never rotates and never runs `postrotate`. This performs a real rotation, so it
# belongs on a disposable host or in an image build, never on a box that is mid-incident.
#
# Exit 0 only when the rotation moved the path to a new inode, every NGINX descriptor on an
# access log points at that new inode, and the new file is receiving writes.
#
# Optional env: LOG, RULE, PROBE_URL, SETTLE_S
set -euo pipefail

LOG="${LOG:-/var/log/nginx/access.log}"
RULE="${RULE:-/etc/logrotate.d/nginx}"
PROBE_URL="${PROBE_URL:-http://127.0.0.1/}"
SETTLE_S="${SETTLE_S:-10}"

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

command -v logrotate >/dev/null || die "logrotate is not installed"
pgrep nginx >/dev/null || die "NGINX is not running, so there is no descriptor to reopen"
[[ -f "$RULE" ]] || die "no logrotate rule at ${RULE}"
[[ -f "$LOG" ]] || die "no log file at ${LOG}"

# Descriptors NGINX holds on anything whose name starts with the log's, as "target inode".
# A failed reopen leaves NGINX on the renamed `access.log.1`, which is still linked, so
# `lsof +L1` would see nothing; the target name is what distinguishes the two states.
held() {
  local pid fd target
  for pid in $(pgrep nginx); do
    for fd in /proc/"$pid"/fd/*; do
      [[ -e "$fd" ]] || continue
      target="$(readlink "$fd" 2>/dev/null)" || continue
      case "$target" in
        "${LOG}"*) printf '%s %s\n' "$target" "$(stat -Lc %i "$fd" 2>/dev/null)" ;;
      esac
    done
  done | sort -u
}

curl -fsS -o /dev/null --max-time 5 "$PROBE_URL" || die "cannot reach ${PROBE_URL} to generate a log line"
before="$(stat -c %i "$LOG")"
say "before: ${LOG} is inode ${before}"

logrotate -f "$RULE"

after=""
for ((i = 0; i < SETTLE_S; i++)); do
  after="$(stat -c %i "$LOG" 2>/dev/null || true)"
  [[ -n "$after" && "$after" != "$before" ]] && break
  sleep 1
done
[[ -n "$after" ]] || die "no file at ${LOG} after rotation"
[[ "$after" != "$before" ]] || die "rotation left the same inode ${before} at ${LOG}; it did not rotate"
say "after:  ${LOG} is inode ${after}"

# A working `postrotate` signals NGINX, which reopens asynchronously, so give it time to
# converge rather than sampling once.
for ((i = 0; i < SETTLE_S; i++)); do
  mapfile -t rows < <(held)
  stale=0
  for row in ${rows[@]+"${rows[@]}"}; do
    [[ "$row" == "${LOG} ${after}" ]] || stale=1
  done
  ((${#rows[@]} > 0)) && ((stale == 0)) && break
  sleep 1
done

((${#rows[@]} > 0)) || die "no NGINX descriptor points at ${LOG}*; NGINX is not logging there at all"
printf '  holds: %s\n' "${rows[@]}"
for row in "${rows[@]}"; do
  [[ "$row" == "${LOG} ${after}" ]] ||
    die "NGINX still holds '${row}' instead of ${LOG} at inode ${after}: postrotate did not make it reopen"
done

curl -fsS -o /dev/null --max-time 5 "$PROBE_URL" || die "cannot reach ${PROBE_URL} after rotation"
size=0
for ((i = 0; i < SETTLE_S; i++)); do
  size="$(stat -c %s "$LOG")"
  ((size > 0)) && break
  sleep 1
done
((size > 0)) || die "${LOG} is still empty after a request: NGINX is writing somewhere else"

say "PASS: rotation moved ${LOG} to inode ${after}, NGINX reopened it, and it grew to ${size} bytes"
