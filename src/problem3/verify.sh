#!/usr/bin/env bash
# Verifies the behaviour of the current stack, and separately demonstrates the original
# connection-leak pattern side by side with the fixed one. It does not re-create the
# original broken stack: the historical failures are described in SOLUTION.md.
# Requires Docker and jq.
#
# Each check states exactly what it asserts. Status, body and timing always come
# from the SAME request, so a check cannot pass for the wrong reason.
#
# Usage: ./verify.sh [--keep]
set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
COMPOSE="docker compose"
PROJECT="problem3"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

PASS=0
FAIL=0
RESULTS=()

pass() {
  PASS=$((PASS + 1))
  RESULTS+=("PASS  $1")
  printf '  \033[32mPASS\033[0m  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  RESULTS+=("FAIL  $1")
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
}

section() { printf '\n==> %s\n' "$1"; }

# probe <url> — sets PROBE_CODE, PROBE_TIME and PROBE_BODY from ONE request
PROBE_CODE=""
PROBE_TIME=""
PROBE_BODY=""
probe() {
  local raw meta
  raw="$(curl -s -m 30 -w $'\n%{http_code} %{time_total}' "$1" 2>/dev/null)"
  if [[ -z "$raw" ]]; then
    PROBE_CODE="000"
    PROBE_TIME="0"
    PROBE_BODY=""
    return
  fi
  meta="$(printf '%s' "$raw" | tail -n 1)"
  PROBE_BODY="$(printf '%s' "$raw" | sed '$d')"
  PROBE_CODE="${meta%% *}"
  PROBE_TIME="${meta##* }"
  [[ "$PROBE_CODE" =~ ^[0-9]{3}$ ]] || PROBE_CODE="000"
}

# assert_code <url> <want> <label>
assert_code() {
  probe "$1"
  if [[ "$PROBE_CODE" == "$2" ]]; then
    pass "$3 -> $PROBE_CODE"
  else
    fail "$3 -> $PROBE_CODE (want $2)"
  fi
}

api_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${PROJECT}-api-1" 2>/dev/null
}

cleanup() {
  docker rm -f p3-decoy >/dev/null 2>&1
  if [[ $KEEP -eq 0 ]]; then
    section "Teardown"
    $COMPOSE down -v --remove-orphans >/dev/null 2>&1
    echo "  stack removed (pass --keep to leave it running)"
  fi
}
trap cleanup EXIT

section "Environment"
docker version --format 'docker {{.Server.Version}}'
$COMPOSE version
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

section "0. Compose config is valid with no .env file and no overrides in the environment"
# --env-file /dev/null stops Compose loading a local .env, and the documented overrides are
# unset for this one command, so this really proves the built-in defaults are sufficient.
# shellcheck disable=SC2086  # $COMPOSE is deliberately two words
if env -u POSTGRES_DB -u POSTGRES_USER -u POSTGRES_PASSWORD -u APP_DB_USER -u APP_DB_PASSWORD \
  -u DB_POOL_MAX -u MAX_INFLIGHT -u DRAIN_TEST_DELAY_MS \
  $COMPOSE --env-file /dev/null config >/dev/null 2>&1; then
  pass "docker compose config parses with no .env and no overrides (built-in defaults only)"
else
  fail "docker compose config parses with no .env and no overrides"
fi

section "1. Start the stack and wait for healthchecks"
if $COMPOSE up --build -d --wait >/dev/null 2>&1; then
  pass "all services became healthy (the API probe is /ready, so the database is up too)"
else
  fail "all services became healthy"
  $COMPOSE ps
fi
$COMPOSE ps --format '  {{.Name}}\t{{.Status}}'

# The original stack never mounted postgres/init.sql, so its settings were silently dead.
# The value alone cannot prove the mount landed, because the value we want happens to be the
# server default. What distinguishes them is where the setting came from: `ALTER SYSTEM`
# writes postgresql.auto.conf, and a server that never ran the script reports no source file.
# shellcheck disable=SC2016  # the container expands these, not this shell
pg_query='psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc'
running_max="$($COMPOSE exec -T postgres sh -c "$pg_query \"SHOW max_connections\"" 2>/dev/null | tr -d '[:space:]')"
max_source="$($COMPOSE exec -T postgres sh -c "$pg_query \"SELECT coalesce(sourcefile, '(default)') FROM pg_settings WHERE name = 'max_connections'\"" 2>/dev/null | tr -d '[:space:]')"
if [[ "$running_max" == "100" ]] && [[ "$max_source" == */postgresql.auto.conf ]]; then
  pass "postgres/init.sql really ran: max_connections=${running_max} sourced from ${max_source##*/}, not the built-in default"
else
  fail "postgres/init.sql really ran: max_connections=${running_max:-<unreadable>} source=${max_source:-<unreadable>}, expected 100 from postgresql.auto.conf"
fi

section "2. Routing (the original stack answered 502 on /api and 404 on /status)"
assert_code "$BASE_URL/" 200 "GET /           "

probe "$BASE_URL/api/users"
if [[ "$PROBE_CODE" == "200" ]] && [[ "$(jq -r '.ok' <<<"$PROBE_BODY" 2>/dev/null)" == "true" ]]; then
  pass "GET /api/users   -> 200, ok=true, cache=$(jq -r '.cache' <<<"$PROBE_BODY"), in ${PROBE_TIME}s"
else
  fail "GET /api/users   -> $PROBE_CODE body=$PROBE_BODY"
fi

assert_code "$BASE_URL/status" 200 "GET /status      (was 404: nginx had no route)"
assert_code "$BASE_URL/ready" 200 "GET /ready      "

# The variable form of proxy_pass is easy to get wrong in a way that mangles the
# path, so prove the path itself arrives: an unknown route makes the API echo the
# exact path it received. A 200 alone would not show that.
probe "$BASE_URL/api/does-not-exist?probe=1&enc=%20x"
if [[ "$PROBE_CODE" == "404" ]] && grep -q 'Cannot GET /api/does-not-exist' <<<"$PROBE_BODY"; then
  pass "the API received the exact path: it answered 404 with 'Cannot GET /api/does-not-exist'"
else
  fail "path forwarding through the proxy: got $PROBE_CODE, body=$(head -c 120 <<<"$PROBE_BODY")"
fi
# Not just "200 with a query string attached": the API echoes the URL it received, so a
# proxy that dropped or rewrote the query would fail this check.
probe "$BASE_URL/api/echo?probe=1&enc=%20x"
echoed_url=$(jq -r '.original_url // empty' <<<"$PROBE_BODY" 2>/dev/null)
echoed_enc=$(jq -r '.query.enc // empty' <<<"$PROBE_BODY" 2>/dev/null)
if [[ "$PROBE_CODE" == "200" && "$echoed_url" == "/api/echo?probe=1&enc=%20x" && "$echoed_enc" == " x" ]]; then
  pass "the query string arrived intact and decoded: original_url='$echoed_url', enc='$echoed_enc'"
else
  fail "query string through the proxy: code=$PROBE_CODE url='$echoed_url' enc='$echoed_enc'"
fi

section "3. The Postgres client is not leaked on query failure"
leak_out=$($COMPOSE run --rm --no-deps -v "$PWD/tests:/app/tests:ro" api \
  node tests/pool-leak-demo.js 2>/dev/null)
leak_rc=$?
printf '  %s\n' "${leak_out//$'\n'/$'\n'  }"
if [[ $leak_rc -eq 0 ]]; then
  pass "the old pattern exhausts its pool at attempt $(jq -r '.buggy.exhaustedAtAttempt' <<<"$leak_out"); pool.query survives $(jq -r '.fixed.queryErrors' <<<"$leak_out") failures and still serves"
else
  fail "pool leak demonstration (exit $leak_rc)"
fi

section "4. A cache outage degrades the response, it does not fail it"
$COMPOSE stop redis >/dev/null 2>&1
probe "$BASE_URL/api/users"
if [[ "$PROBE_CODE" == "200" ]] && [[ "$(jq -r '.cache' <<<"$PROBE_BODY" 2>/dev/null)" == "degraded" ]]; then
  pass "redis down: the same request returned 200 with cache=degraded in ${PROBE_TIME}s"
else
  fail "redis down: GET /api/users -> $PROBE_CODE body=$PROBE_BODY"
fi
assert_code "$BASE_URL/ready" 200 "redis down: /ready (the cache is optional, so still ready)"
$COMPOSE start redis >/dev/null 2>&1
sleep 3

section "5. A database outage fails fast instead of hanging (it used to wait unbounded)"
$COMPOSE stop postgres >/dev/null 2>&1
probe "$BASE_URL/api/users"
db_code="$PROBE_CODE"
db_time="$PROBE_TIME"
if [[ "$db_code" == "503" ]] && awk "BEGIN{exit !($db_time < 5)}"; then
  pass "postgres down: the same request returned 503 in ${db_time}s (bounded connect timeout)"
else
  fail "postgres down: GET /api/users -> $db_code in ${db_time}s (want 503 in under 5 s)"
fi
assert_code "$BASE_URL/ready" 503 "postgres down: /ready (not ready)"
api_before="$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' "${PROJECT}-api-1" 2>/dev/null)"
$COMPOSE start postgres >/dev/null 2>&1
for _ in $(seq 1 20); do
  probe "$BASE_URL/api/users"
  [[ "$PROBE_CODE" == "200" ]] && break
  sleep 1
done
assert_code "$BASE_URL/api/users" 200 "postgres back: GET /api/users"
api_after="$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' "${PROJECT}-api-1" 2>/dev/null)"
if [[ -n "$api_after" && "$api_before" == "$api_after" ]]; then
  pass "the API recovered without restarting: same container and start time"
else
  fail "the API container changed during the database outage (before='$api_before' after='$api_after')"
fi

section "5b. A burst is shed immediately instead of queueing in the API's heap"
MAX_INFLIGHT=2 DRAIN_TEST_DELAY_MS=2000 $COMPOSE up -d --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 30); do
  probe "$BASE_URL/live"
  [[ "$PROBE_CODE" == "200" ]] && break
  sleep 1
done
shed_dir=$(mktemp -d)
for i in $(seq 1 8); do
  (curl -s -o /dev/null -m 20 -w '%{http_code} %header{retry-after}' "$BASE_URL/api/users" > "$shed_dir/$i") &
done
wait
shed_503=$(grep -c '^503' "$shed_dir"/* 2>/dev/null | grep -c ':1$')
shed_200=$(grep -c '^200' "$shed_dir"/* 2>/dev/null | grep -c ':1$')
shed_retry=$(grep -h '^503' "$shed_dir"/* 2>/dev/null | head -1)
rm -rf "$shed_dir"
if ((shed_503 > 0)) && ((shed_200 > 0)) && [[ "$shed_retry" == *"1"* ]]; then
  pass "with MAX_INFLIGHT=2: ${shed_200} served, ${shed_503} shed as 503 with Retry-After, none queued"
else
  fail "in-flight cap: 200s=${shed_200} 503s=${shed_503} first-503='${shed_retry}'"
fi
$COMPOSE up -d --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 30); do
  probe "$BASE_URL/api/users"
  [[ "$PROBE_CODE" == "200" ]] && break
  sleep 1
done

section "6. nginx recovers when the API container changes IP, with no reload"
nginx_before="$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' "${PROJECT}-nginx-1" 2>/dev/null)"
old_ip=$(api_ip)
$COMPOSE stop api >/dev/null 2>&1
docker run -d --rm --name p3-decoy --network "${PROJECT}_default" alpine sleep 180 >/dev/null 2>&1
start_ts=$SECONDS
$COMPOSE up -d --force-recreate --no-deps api >/dev/null 2>&1
recovered=""
for _ in $(seq 1 40); do
  probe "$BASE_URL/api/users"
  if [[ "$PROBE_CODE" == "200" ]]; then
    recovered=$((SECONDS - start_ts))
    break
  fi
  sleep 1
done
new_ip=$(api_ip)
echo "  api IP: $old_ip -> $new_ip (the timer started before the container was recreated)"
if [[ -n "$old_ip" && -n "$new_ip" && "$old_ip" != "$new_ip" ]]; then
  pass "the API container really changed IP ($old_ip -> $new_ip)"
else
  fail "could not force an IP change (old=$old_ip new=$new_ip), so the DNS check below is inconclusive"
fi
if [[ -n "$recovered" ]]; then
  pass "/api/users served 200 again ${recovered}s after recreation, measured from before recreation"
else
  fail "nginx never recovered within 40 s (stale upstream resolution)"
fi
# Two ways the recovery could be explained away, both excluded: a reload signal,
# or nginx itself having restarted (which would re-resolve on startup).
reloads=$($COMPOSE logs nginx 2>/dev/null | grep -c 'signal process started')
nginx_after="$(docker inspect -f '{{.Id}} {{.State.StartedAt}}' "${PROJECT}-nginx-1" 2>/dev/null)"
if [[ "${reloads:-0}" -eq 0 && "$nginx_before" == "$nginx_after" && -n "$nginx_after" ]]; then
  pass "no reload signal, and the nginx container is the same one with the same start time"
else
  fail "cannot attribute recovery to re-resolution (reload signals: ${reloads:-0}; nginx before='$nginx_before' after='$nginx_after')"
fi
docker rm -f p3-decoy >/dev/null 2>&1

section "7. Graceful shutdown: requests in flight when SIGTERM arrives still complete"
# Recreate the API with a deliberate 3 s delay on /api/users so that requests are
# genuinely in flight when the signal lands. Without it the responses are so fast
# that nothing is ever draining, and the check would prove nothing.
DRAIN_TEST_DELAY_MS=3000 $COMPOSE up -d --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 30); do
  probe "$BASE_URL/live"
  [[ "$PROBE_CODE" == "200" ]] && break
  sleep 1
done
drain_dir=$(mktemp -d)
for i in $(seq 1 5); do
  (curl -s -o /dev/null -m 25 -w '%{http_code}' "$BASE_URL/api/users" > "$drain_dir/$i") &
done
sleep 1                                   # the five requests are now inside the 3 s delay
$COMPOSE stop -t 20 api >/dev/null 2>&1   # SIGTERM arrives mid-flight
wait
drain_ok=$(grep -lx '200' "$drain_dir"/* 2>/dev/null | wc -l | tr -d ' ')
drain_codes=$(cat "$drain_dir"/* 2>/dev/null | tr '\n' ' ')
rm -rf "$drain_dir"
if [[ "$drain_ok" == "5" ]]; then
  pass "all 5 in-flight requests completed with 200 after SIGTERM (codes: $drain_codes)"
else
  fail "only ${drain_ok}/5 in-flight requests completed after SIGTERM (codes: $drain_codes)"
fi
logs=$($COMPOSE logs api --tail 40 2>/dev/null)
# Order, not just presence: compare the line numbers of the two messages.
closed_line=$(grep -n '"msg":"http server closed, draining dependencies"' <<<"$logs" | tail -1 | cut -d: -f1)
done_line=$(grep -n '"msg":"shutdown complete"' <<<"$logs" | tail -1 | cut -d: -f1)
if [[ -n "$closed_line" && -n "$done_line" ]] && ((closed_line < done_line)); then
  pass "shutdown was ordered: 'http server closed' at line ${closed_line}, 'shutdown complete' at ${done_line}"
else
  fail "the API did not log an ordered shutdown (closed=${closed_line:-none} complete=${done_line:-none})"
  printf '%s\n' "$logs" | tail -5 | sed 's/^/  /'
fi
$COMPOSE up -d --force-recreate --no-deps api >/dev/null 2>&1

section "Summary"
printf '%s\n' "${RESULTS[@]}" | sed 's/^/  /'
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
