#!/usr/bin/env bash
# Read-only triage for "disk nearly full" on an NGINX load balancer.
#
# No command here writes, deletes, truncates, mounts, signals or restarts anything:
# `nginx -t` and `nginx -T` are deliberately absent because loading the running
# configuration can open, and create, the files it names. The configuration is read from
# disk instead.
#
# Collections go through one of three wrappers, each of which bounds the command with
# `timeout` (20 s, or 120 s for the two filesystem walks) and records a non-zero exit or a
# timeout: `run` for an ordinary command, `presence` for a command whose output is filtered,
# and `presence_files` for configuration files, where an absent file is an answer and an
# unreadable one is a gap. The one exception is the `lsof` collection, which needs
# `PIPESTATUS` to tell lsof's own status from awk's and is therefore bounded and
# status-checked inline, in section 5. Nested shells are started with `-o pipefail`, because a new shell
# does not inherit it, so a failed `dmesg`, `du` or `find` cannot be masked by a successful
# `tail`, `sort` or `awk`, and no pipeline truncates with `head`, whose early exit would
# surface as SIGPIPE. A producer failure is always a gap unless the caller passes
# `presence -n <rc>`, which only the `dpkg -l` call does. The script exits non-zero when
# anything was missing, timed out or failed, so a truncated collection is never mistaken for
# a clean bill of health.
#
# Usage: sudo ./diagnose.sh [path on the alerted filesystem]   (default: /)
set -uo pipefail

TARGET="${1:-/}"
NICE=(nice -n 19 ionice -c3)
RUN_TIMEOUT="${RUN_TIMEOUT:-20}"        # cheap metadata commands
WALK_TIMEOUT="${WALK_TIMEOUT:-120}"     # filesystem walks
missing=()
incomplete=()
essential_failed=0

# One field per line from lsof -F: p=pid c=command f=descriptor D=device i=inode s=size
# n=name. Unique usage is keyed by device+inode, because an inode number is unique only
# within a filesystem, and every holder is printed, because reopening or truncating needs
# the right pid and descriptor.
# shellcheck disable=SC2016  # an awk program, not a shell string
readonly LSOF_AWK='
  /^p/ { pid = substr($0, 2); next }
  /^c/ { cmd = substr($0, 2); next }
  /^f/ { fd  = substr($0, 2); next }
  /^D/ { dv  = substr($0, 2); next }
  /^i/ { ino = substr($0, 2); next }
  /^s/ { size = substr($0, 2); next }
  /^n/ {
    key = dv "/" ino
    printf "  %10.1f MB  %-16s fd %-5s dev %-10s inode %-12s %s\n", \
      size/1048576, cmd "/" pid, fd, dv, ino, substr($0, 2)
    if (!(key in seen)) { seen[key] = 1; unique += size }
    next
  }
  END {
    printf "  -- unique deleted-but-open bytes on this filesystem: %.1f MB\n", unique/1048576
    print  "  -- reopen or truncate through the pid and fd shown above, never by path"
  }'

hr() { printf '\n----- %s\n' "$1"; }

# Bounds the command and records what could not be collected, instead of letting a failure
# pass silently. `presence` and `presence_files` do the same for filtered output and for
# configuration files; the `lsof` pipeline is the one collection checked inline.
run() { # run [-t seconds] [-1] <label> <command...>
  local limit="$RUN_TIMEOUT" nomatch_ok=0
  while true; do
    case "${1:-}" in
      -t)
        limit="$2"
        shift 2
        ;;
      -1) # exit 1 means "nothing matched", which is an answer, not a gap
        nomatch_ok=1
        shift
        ;;
      *) break ;;
    esac
  done
  local label="$1"
  shift
  timeout "$limit" "$@"
  local rc=$?
  case "$rc" in
    0) ;;
    1) ((nomatch_ok)) || incomplete+=("${label}: exit 1") ;;
    124) incomplete+=("${label}: timed out after ${limit}s, output is partial") ;;
    *) incomplete+=("${label}: exit ${rc}") ;;
  esac
  ((nomatch_ok && rc == 1)) && return 0
  return "$rc"
}

# Presence checks: exit 1 from the filter means "nothing matched", which is an answer;
# anything else is a gap. The producer runs on its own first, so a producer failure can
# never be mistaken for an empty result, and nothing is truncated with `head` in a pipe
# (which would surface as SIGPIPE 141 under pipefail).
presence() { # presence [-n <rc>] <label> <none-message> <filter-regex> <producer...>
  # -n names the exit code this particular producer uses for "nothing found". Only the
  # `dpkg -l` call passes it, because dpkg documents exit 1 as "no package found" and uses 2
  # for real errors. Without -n, any non-zero producer exit is a gap, so a failure is never
  # reported as an empty result.
  local nothing_rc=""
  if [[ "${1:-}" == "-n" ]]; then
    nothing_rc="$2"
    shift 2
  fi
  local label="$1" none="$2" regex="$3"
  shift 3
  local out rc
  out="$(timeout "$RUN_TIMEOUT" "$@" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) ;;
    124)
      incomplete+=("${label}: timed out after ${RUN_TIMEOUT}s")
      return 0
      ;;
    *)
      if [[ -n "$nothing_rc" && "$rc" == "$nothing_rc" ]]; then
        printf '%s\n' "$none"
      else
        incomplete+=("${label}: producer exit ${rc}")
      fi
      return 0
      ;;
  esac
  if [[ -z "$regex" ]]; then
    [[ -n "$out" ]] && printf '%s\n' "$out" || printf '%s\n' "$none"
    return 0
  fi
  local matched
  matched="$(grep -Ei "$regex" <<<"$out" || true)"
  [[ -n "$matched" ]] && printf '%s\n' "$matched" || printf '%s\n' "$none"
  return 0
}

# Same idea for configuration files: an absent file is an answer, an unreadable one is a gap.
presence_files() { # presence_files <label> <none-message> <filter-regex> <file...>
  local label="$1" none="$2" regex="$3"
  shift 3
  local existing=() f
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    if [[ -r "$f" ]]; then
      existing+=("$f")
    else
      incomplete+=("${label}: ${f} exists but is not readable")
    fi
  done
  if ((${#existing[@]} == 0)); then
    printf '%s\n' "$none"
    return 0
  fi
  local out rc
  out="$(timeout "$RUN_TIMEOUT" grep -Ehi "$regex" "${existing[@]}" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    1) printf '%s\n' "$none" ;;
    124) incomplete+=("${label}: timed out after ${RUN_TIMEOUT}s") ;;
    *) incomplete+=("${label}: grep exit ${rc}") ;;
  esac
  return 0
}

need() { # need <command> <package>
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  missing+=("$1 (package: $2)")
  return 1
}

printf 'disk triage on %s at %s\n' "$(hostname)" "$(date -Is)"
if [[ "$(id -u)" -ne 0 ]]; then
  printf 'WARNING: not running as root; log reads, dmesg and per-process descriptors will be incomplete.\n'
  incomplete+=("whole run: not root")
fi

hr "0. which filesystem is actually full (never assume /)"
if need findmnt util-linux; then
  if resolved="$(timeout "$RUN_TIMEOUT" findmnt -no TARGET,SOURCE,FSTYPE --target "$TARGET" 2>/dev/null)"; then
    read -r MOUNT DEV FSTYPE <<<"$resolved"
  else
    incomplete+=("resolving the filesystem for ${TARGET}: findmnt failed, so the scope below is a guess")
    MOUNT="" DEV="" FSTYPE=""
  fi
else
  MOUNT="$TARGET" DEV="" FSTYPE=""
fi
MOUNT="${MOUNT:-$TARGET}"
printf 'alerted path %s -> mountpoint %s on %s (%s)\n' "$TARGET" "$MOUNT" "${DEV:-unknown}" "${FSTYPE:-unknown}"
echo "-- every local filesystem, so a full /var/log on its own volume is visible too:"
run "df -hT" df -hT -x tmpfs -x devtmpfs -x squashfs || essential_failed=1

# on_target <path> — true when the path lives on the alerted filesystem, so a `du` of it
# measures the space that is actually short.
on_target() {
  [[ -e "$1" ]] || return 1
  [[ -n "$DEV" ]] || return 0   # scope unknown: report it rather than silently skipping
  local dev
  if ! dev="$(timeout "$RUN_TIMEOUT" findmnt -no SOURCE --target "$1" 2>/dev/null)"; then
    incomplete+=("resolving the filesystem for ${1}")
    return 1
  fi
  [[ "$dev" == "$DEV" ]]
}

hr "1. capacity and inodes (bytes and inodes fail with the same message)"
run "df -h" df -h "$MOUNT" || essential_failed=1
run "df -i" df -i "$MOUNT" || essential_failed=1

hr "2. filesystem health (a read-only or erroring filesystem is not a capacity problem)"
run "findmnt options" findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS --target "$MOUNT" || true
if need dmesg util-linux; then
  run "dmesg" bash -o pipefail -c 'dmesg --level=err,warn 2>/dev/null | tail -15' || true
fi

hr "3. reserved blocks (counted as used, usable only by root)"
if [[ -n "$DEV" && "$FSTYPE" =~ ^ext[234]$ ]] && need tune2fs e2fsprogs; then
  presence "tune2fs" "no reserved-block fields reported" \
    'reserved block (count|percent)|^Block count' tune2fs -l "$DEV"
else
  echo "skipped: not ext2/3/4, or tune2fs unavailable"
fi

hr "4. is the filesystem smaller than the disk?"
if need lsblk util-linux; then
  run "lsblk" lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT || true
fi
if need vgs lvm2; then
  run "vgs" vgs || true
  run "lvs" lvs || true
fi

hr "5. deleted-but-open files (why du can disagree with df)"
if need lsof lsof; then
  # A mount point argument makes lsof report only files open on that filesystem.
  timeout "$RUN_TIMEOUT" lsof -nP -a +L1 "$MOUNT" -F pcfDisn 2>/dev/null | awk "$LSOF_AWK"
  rc=${PIPESTATUS[0]}
  # lsof exits 1 when nothing matches, which here is good news, not a failure.
  case "$rc" in
    0 | 1) ;;
    124) incomplete+=("lsof +L1: timed out") ;;
    *) incomplete+=("lsof +L1: exit ${rc}") ;;
  esac
else
  echo "  falling back to /proc: descriptors only, no sizes"
  run "proc fd scan" bash -o pipefail -c "find /proc/[0-9]*/fd -lname '*(deleted)*' -printf '  %p -> %l\n' 2>/dev/null | awk 'NR<=20'" || true
fi

hr "6. largest directories on the alerted filesystem (bounded, low priority)"
# shellcheck disable=SC2016  # $1 is the inner shell's argument
run -t "$WALK_TIMEOUT" "du depth 1" "${NICE[@]}" bash -o pipefail -c \
  'du -xh --max-depth=1 "$1" 2>/dev/null | sort -h | tail -15' _ "$MOUNT" || essential_failed=1
echo "note: -x stops at mount boundaries, so anything on another filesystem is counted by df -hT above, not here"

hr "7. the usual suspects, only those on this filesystem"
for d in /var/log /var/log/nginx /var/log/journal /var/lib/nginx /var/cache/nginx /var/cache/apt \
  /var/lib/systemd/coredump /var/crash /tmp /var/tmp /root /home; do
  if on_target "$d"; then
    run "du ${d}" "${NICE[@]}" du -xsh "$d" || true
  fi
done

hr "8. biggest individual files"
# shellcheck disable=SC2016  # $1 is the inner shell's argument; the awk body is quoted for awk
run -t "$WALK_TIMEOUT" "find large files" "${NICE[@]}" bash -o pipefail -c \
  'find "$1" -xdev -type f -size +200M -printf "%s\t%p\n" 2>/dev/null | sort -rn |
   awk -F"\t" "NR<=10 { printf \"  %10.1f MB  %s\\n\", \$1/1048576, \$2 }"' _ "$MOUNT" || true

hr "9. journald usage and configured cap"
if need journalctl systemd; then
  run "journalctl --disk-usage" journalctl --disk-usage || true
fi
presence_files "journald config" "no explicit journald limits configured (defaults apply)" \
  '^(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|Storage)' \
  /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf

hr "10. where nginx writes, read from the configuration files on disk"
if [[ -d /etc/nginx ]]; then
  run -1 "nginx config grep" grep -RnsE \
    '^[[:space:]]*(access_log|error_log|log_format|proxy_temp_path|client_body_temp_path|proxy_cache_path|proxy_max_temp_file_size|client_max_body_size)' \
    /etc/nginx
  echo "note: include directives may pull in files outside /etc/nginx; grep those paths too."
else
  echo "FINDING: /etc/nginx is absent on a box whose only job is NGINX — confirm this is the right host"
  incomplete+=("nginx configuration: /etc/nginx is absent")
fi

hr "11. logrotate for nginx and for the OS logs"
if [[ ! -f /etc/logrotate.d/nginx ]]; then
  echo "FINDING: no /etc/logrotate.d/nginx — unbounded logs (cause 1) is the leading explanation"
fi
for f in /etc/logrotate.d/nginx /etc/logrotate.d/rsyslog /etc/logrotate.conf; do
  if [[ -f "$f" ]]; then
    printf -- '-- %s\n' "$f"
    run "read ${f}" sed -n '1,25p' "$f" || true
  fi
done
echo "-- last rotation timestamps (logrotate state):"
presence_files "logrotate state" "no logrotate state entries for nginx or syslog" \
  'nginx|syslog' /var/lib/logrotate/status

hr "12. space hidden under a mount point"
echo "not automated: it needs a bind mount, which this script will not do. Once traffic is safe:"
printf '  mkdir -p /mnt/fscheck && mount --bind %s /mnt/fscheck && du -xsh /mnt/fscheck/*\n' "$MOUNT"

hr "13. package, kernel and snap leftovers"
need curl curl || true
if need dpkg dpkg; then
  presence -n 1 "dpkg kernels" "no linux-image packages found" '^ii[[:space:]]+linux-image' \
    dpkg -l 'linux-image-*'
fi
if command -v snap >/dev/null 2>&1; then
  # No -n here: snap also exits 1 when it cannot reach snapd, which is a gap, not an answer.
  presence "snap revisions" "no disabled snap revisions" 'disabled' snap list --all
fi

hr "collection summary"
if ((${#missing[@]})); then
  printf 'MISSING TOOLS (do not apt-get install while the filesystem is full):\n'
  printf '  - %s\n' "${missing[@]}"
fi
if ((${#incomplete[@]})); then
  printf 'INCOMPLETE SECTIONS:\n'
  printf '  - %s\n' "${incomplete[@]}"
fi
if ((essential_failed)) || ((${#incomplete[@]})) || ((${#missing[@]})); then
  printf '\ntriage finished with gaps: treat the output above as partial, and collect the\nmissing evidence another way before concluding anything. Nothing was modified.\n'
  exit 1
fi
printf '\nread-only triage complete, no gaps. Nothing was modified.\n'
