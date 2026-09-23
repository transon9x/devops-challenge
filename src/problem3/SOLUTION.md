# Problem 3: Debugging issues within system

## Assumptions

- The deliverable is the report below plus the fixed stack in this directory. The original
  layout and file names are kept so the diff stays readable.
- No orchestrator is available here, so readiness and liveness are wired to Compose
  healthchecks. In production the same endpoints feed the platform's probes.
- The evidence below was produced on Docker 29.1.3 with Compose v2.40.3. `./verify.sh`
  re-runs the current-stack checks and fault injections in one command. It does not
  reproduce the original stack, so the section 1 findings are not re-measured — except the
  connection leak, which it demonstrates side by side with the fixed pattern.
- The stack binds to `127.0.0.1:8080` and runs from the defaults in `docker-compose.yml`,
  so `docker compose up --build` works with no `.env` file. Those defaults include
  **local-only development passwords** for Postgres, which is why the stack is bound to
  loopback; no production secret is committed, and `.env.example` documents the overrides a
  real environment must supply.

## 1. What problems I found

The findings are split into what the checked-in stack **always** did and what was **latent**
behind it. The reported symptom ("unreliable and sometimes inaccessible") is explained by
the first group; the second group is what would have hurt in production once the first was
fixed.

### Deterministic, reproducible on the unmodified stack

| # | Problem | Evidence |
|---|---|---|
| 1 | **nginx proxies to the wrong port.** `proxy_pass http://api:3001` while the API listens on 3000, so every `/api/*` request fails. | `GET /api/users` → **502** in 2 ms, 100 % of requests. nginx log: `connect() failed (111: Connection refused) ... upstream: "http://172.20.0.4:3001/api/users"` |
| 2 | **The health endpoint is unreachable from outside.** The API serves `/status`, but nginx only has a `location /api/`, so the only ingress cannot health-check the app. | `GET /status` → **404** from nginx, `open() "/etc/nginx/html/status" failed` |
| 3 | **`postgres/init.sql` is never mounted.** It is not in `/docker-entrypoint-initdb.d`, so `ALTER SYSTEM SET max_connections = 20` is dead code. | `show max_connections` → **100** (the default), not 20 |

This is why the platform looked half-alive: `/` is served by nginx itself and always
returned 200, while everything behind the proxy was down. A user hitting the landing page
sees a working platform; a user hitting the API sees a broken one.

### Latent, exposed as soon as the routing bug is fixed

I patched only the port (`3001` → `3000`) on the original code and re-tested. The
requests then succeeded in 26 ms, and these bugs became visible:

| # | Problem | Why it happens | Evidence |
|---|---|---|---|
| 4 | **The request hangs indefinitely when Postgres is unavailable.** | `pg.Pool` defaults to `connectionTimeoutMillis: 0`, meaning wait forever. No `statement_timeout` either. | postgres stopped: first request **never returned** (client gave up at 45 s), second returned 502 after **14.3 s** |
| 5 | **A cache outage fails the whole request.** | `redis.set` is awaited on the response path and its rejection falls into the same `catch` as the database error, although nothing reads that key. | redis stopped: `GET /api/users` → **502 after 3.1 s** |
| 6 | **The Postgres client leaks on every failed query.** `db.release()` is only reached after a successful `db.query(...)`; an error skips it. | After `max` failures the pool is empty and `pool.connect()` waits forever (see #4 for why it never errors). | Demonstrated: with `max: 5`, the `connect/query/release` pattern **exhausts the pool at attempt 6**; `pool.query()` survives 8 consecutive failures and the pool is still usable |
| 7 | **No `pool.on("error")` handler.** | node-postgres documents that errors on idle clients surface as uncaught errors, which can take the process down. | Code inspection; combined with #8 this is unrecoverable |
| 8 | **No restart policy and no healthchecks.** | `restart` is unset, so a crashed API stays dead; `depends_on` without `condition` only orders container *start*, not readiness, so the API can boot before Postgres accepts connections. | `docker inspect` → `RestartPolicy: no`, `Healthcheck: none` |
| 9 | **nginx resolves the upstream once, at startup.** | With a literal hostname in `proxy_pass` and no `resolver`, the IP is cached for the life of the worker. Recreating the API with a different IP produces 502s until nginx is reloaded. | Forced an IP change (172.20.0.4 → 172.20.0.6) by parking a decoy container on the freed address: the original config 502s, the fixed config recovers in ~1 s |
| 10 | **No graceful shutdown.** | No `SIGTERM` handler, so in-flight requests are dropped and the pool is never drained on every deploy. | Code inspection |

### Hygiene and security (real, but not the cause of the outage)

- The API runs as **root** (`uid=0`) in the container.
- The API connects to Postgres as the **superuser** with credentials hard-coded in
  `index.js`; the provided `.env` is empty and unused.
- `node:20-alpine` is **end-of-life** (Node 20's scheduled EOL is 2026-04-30 per the
  Node.js release schedule). `nginx:1.25`
  is also an old branch.
- `npm install` without a committed lockfile: builds are not reproducible.
- Postgres has **no named volume**, only an anonymous one (`docker inspect` shows
  `volume:68fa1bab…`), so data is orphaned or lost on `down -v` / recreate.
- No resource limits, so one container can starve the host.
- `nginx/nginx.conf` is an **empty file** that is not mounted. Harmless today, but if
  anyone mounts it at `/etc/nginx/nginx.conf`, nginx will not start. I deleted it.
- `version: "3.9"` is obsolete and Compose warns about it on every command.

## 2. How I diagnosed them

1. **Reproduce and split the symptom.** Brought the stack up unchanged and probed each
   route. `/` returned 200 and `/api/*` returned 502 every single time, which immediately
   rules out "flaky" and points at configuration, not load.
2. **Read the proxy's own error.** The nginx error log names the exact upstream it dialled,
   `172.20.0.4:3001`. Comparing that with the API's own log line, `API running on 3000`,
   is the whole root cause of the outage.
3. **Compare declared config against running state.** `show max_connections` returned 100,
   not the 20 in `init.sql`, which proves the file is never executed; `docker inspect`
   showed no healthcheck, no restart policy and an anonymous volume.
4. **Isolate one variable at a time.** I fixed only the port on the original code so the
   remaining defects could be observed in isolation, then injected faults: stop Postgres,
   stop Redis, force an IP change. Each fault produced a distinct, reproducible signature
   (unbounded hang, 502 from a non-critical dependency, stale DNS).
5. **Prove the leak instead of asserting it.** The connection leak is not visible from the
   HTTP surface, so I wrote [`tests/pool-leak-demo.js`](tests/pool-leak-demo.js), which runs
   the original `connect/query/release` pattern and the fixed `pool.query` pattern against
   the real database and reports when each pool stops serving.
6. **Automate the whole thing.** [`verify.sh`](verify.sh) exercises the **current** stack
   end to end, including the fault injections, and prints a pass/fail table, so the fixes are
   checkable by someone else in one command. It does not rebuild the original broken stack;
   the historical failures are the evidence in section 1, and the leak is demonstrated
   side by side by `tests/pool-leak-demo.js`.

## 3. The fixes I applied

### nginx (`nginx/conf.d/default.conf`)

- `proxy_pass` now targets **port 3000**, and the address is built from variables
  (`http://$api_host:$api_port`) together with `resolver 127.0.0.11 valid=10s`, so the
  upstream is re-resolved at request time instead of once at startup. The variable form is
  used **without** a URI part, so nginx passes its own normalised request URI. `verify.sh`
  proves it by asking `/api/echo?probe=1&enc=%20x` and comparing the URL the API reports
  back, so a proxy that rewrote the path or dropped the query would fail the check.
  Appending `$request_uri` instead would send the raw request target, which can differ from
  the path the location match was made on.
- `resolver_timeout 2s`, because `proxy_connect_timeout` does not bound the DNS lookup.
- Added routes for `/status`, `/live` and `/ready` so the app is observable through the
  ingress.
- Bounded proxy timeouts (`proxy_connect_timeout 2s`, send/read 10 s) so a slow upstream
  cannot pile up connections.
- JSON access log with `request_id`, `upstream_status`, `upstream_connect_time` and
  `upstream_response_time` — the fields the alerts in section 4 are built on. The upstream
  variables are **quoted** in the log format: for a request nginx serves itself they render
  as `-`, and on a retry they can be a comma-separated list, so unquoted they would produce
  invalid JSON.
- Propagates `X-Request-Id` to the API for end-to-end correlation.
- Its own `/nginx-health` endpoint for the container healthcheck.
- **Ingress limits aligned with the API's capacity**: `limit_req` at 50 r/s per client with
  a burst of 25, and `limit_conn` at 32 concurrent requests for the server, both answering
  `503`. Refusing at the edge is cheaper than refusing in the API, and the two limits are
  sized from `DB_POOL_MAX` (8) and `MAX_INFLIGHT` (16).

The address is re-resolved through `resolver 127.0.0.11 valid=10s`, so a container that
comes back on a new IP is picked up within ten seconds, with no reload.

### API (`api/src/index.js`)

- `pool.query()` replaces `connect / query / release`, so the client is **always** returned
  to the pool. Added `pool.on("error")`.
- Bounded everything: `connectionTimeoutMillis: 2000`, `statement_timeout`/`query_timeout`
  5 s, Redis `connectTimeout: 1000`, `commandTimeout: 500`, `maxRetriesPerRequest: 1`,
  `enableOfflineQueue: false`. A dependency outage now fails in milliseconds.
- **Cache failures degrade, they do not fail.** The Redis call has its own `try/catch`; the
  response carries `cache: "ok" | "degraded"`.
- Dependency failure returns **503** (retryable) instead of 500, with the request id.
- Split health: `/live` and `/status` report process liveness; `/ready` checks the database
  with a bounded query and reports Redis as `degraded` **without failing readiness**,
  because the request path serves correctly without the cache. Failing readiness on a Redis
  outage would make an orchestrator remove healthy capacity.
- The Compose healthcheck uses **`/ready`**, not `/live`. With `/live` the container would
  report healthy while the only API route returned 503, which is the same "green while
  broken" failure the original stack had.
- Graceful shutdown on `SIGTERM`/`SIGINT`: stop accepting, drain the HTTP server, then
  `pool.end()` and `redis.quit()`, with a hard 10 s backstop.
- Configuration is **validated at startup**: a missing variable, and any port, pool size or
  timeout that is not an integer in a sane range, exits immediately naming the variable,
  instead of running with `NaN` or a negative timeout that only surfaces under load.
- **Bounded concurrency**: `MAX_INFLIGHT` (default twice the pool size) caps accepted
  requests on `/api`, and excess is refused at once with `503` and `Retry-After`. The pool
  alone would let a burst pile up as waiters until every acquisition timed out, turning a
  spike into a wall of late 503s; `/ready` reports `inflight` and `shed_total` so the
  shedding is visible.
- Structured JSON logs on stdout.

### Compose (`docker-compose.yml`)

- Healthchecks for all four services and `restart: unless-stopped`. Postgres is probed over
  TCP rather than the Unix socket, because during `initdb` the entrypoint runs a temporary
  server on the socket alone and then stops it, so a socket probe reports healthy before the
  real server exists and the first dependents race it. The startup gates are
  deliberately **not** uniform: nginx waits for the API to be healthy and the API waits for
  Postgres to be healthy, because neither can serve without them, while Redis is only
  `condition: service_started`. Gating the API on a healthy cache would contradict the
  degradation the API implements and keep it down for the one outage it is built to survive.
- **Named volume** for Postgres. Redis stays deliberately ephemeral (`--save ""`,
  `--appendonly no`, `maxmemory` + LRU): it is a disposable cache, and saying so explicitly
  is part of the design.
- The published port is now `127.0.0.1:8080`, so a developer VM does not expose the stack.
- Configuration comes from the environment with safe defaults in `docker-compose.yml`, so
  no `.env` is committed; `.env.example` documents the overrides. The API uses a
  **least-privileged role** created by `postgres/20-app-user.sh`, not the superuser. That
  script passes the role name and password as psql variables and lets PostgreSQL quote them
  via `format('%I'/%L')`, so a password containing a quote cannot break or inject SQL.
- `postgres/init.sql` is **actually mounted** now, and sets `max_connections = 100`.
  `superuser_reserved_connections` is 3, so 97 are usable. Pool sizing is explicit at
  `DB_POOL_MAX=8` per replica, and the budget I would hold is **6 replicas (48
  connections)**, leaving roughly half the pool for migrations, monitoring, backups and
  ad-hoc access. Filling 96 of 97 slots would be a sizing bug, not a plan; beyond that
  budget the answer is PgBouncer, not a bigger number. The original `max_connections = 20`
  would have broken at three replicas.
- Runtimes on supported branches: `node:24-alpine`, `postgres:17-alpine`, `redis:8-alpine`,
  and **nginx 1.31.6-alpine pinned by digest** (1.29 is no longer a supported nginx branch).
  CPU/memory limits on every service. Dropped the obsolete `version:` key.
- **The Postgres entrypoint scripts run only on an empty data directory.** Changing
  `APP_DB_PASSWORD` or `init.sql` after the volume exists leaves the old role and settings in
  place, and the API then fails to authenticate. In this local stack the fix is
  `docker compose down -v` to recreate the volume; in production the same change is a
  migration applied by a job, never an init script.
- `npm ci` with a committed `package-lock.json`, and the container runs as `USER node`.

## 4. Monitoring and alerts I would add

**Already emitted by this stack** (the nginx JSON access log, the API's JSON logs and
`/ready`), so these alerts need only a log pipeline:

| Signal | Source | Alert |
|---|---|---|
| Upstream error rate | nginx log, `upstream_status` | > 1 % of requests over 5 min → page. This alone would have caught the original 502 in seconds |
| Upstream connect failures | nginx log, `upstream_connect_time` | sustained occurrence → page: the "wrong port / stale DNS / dead backend" signature |
| Latency | `request_time`, `upstream_response_time` | p99 above the endpoint's SLO for 10 min → ticket |
| Shedding | API log `shedding request`, `/ready` → `load.shed_total` | any sustained shedding → ticket; shedding with low upstream latency means the cap is too low |
| Readiness | `/ready` status and `checks` | not-ready > 1 min → page; `ready` with `redis: degraded` → ticket, not a page |

Parse those fields carefully: nginx writes `-` (not an empty string) when a field has no
value, and on retries `upstream_addr`, `upstream_status`, `upstream_connect_time` and
`upstream_response_time` become **comma- or colon-separated lists**, so an alert must split
them and evaluate the last attempt, not the whole string.

**Needs a collector this stack does not run yet**, and would be added with it:

| Signal | Collector to add | Alert |
|---|---|---|
| Container health | orchestrator events, or cAdvisor | restart count > 3 in 15 min, any `OOMKilled`, readiness failing → page |
| Postgres saturation and availability | `postgres_exporter` (`pg_up`, `pg_stat_activity`) | `numbackends / max_connections` > 80 % → page; `pg_up == 0` for 1 min → page; long waiting queries → ticket |
| Redis | `redis_exporter` (`redis_up`, `evicted_keys`, `rejected_connections`) | down or evictions rising → ticket, since the cache is optional |
| Pool utilisation | API metrics endpoint exposing `pool.totalCount`/`idleCount`/`waitingCount` | waiting clients > 0 for 1 min → ticket: the pool, not the database, is the constraint |
| Host and container saturation | node exporter | CPU, memory and disk thresholds → ticket |

Beyond alerts: ship the JSON logs to a central store and use the `request_id` that now
flows nginx → API to stitch a request together across both. A dashboard with request rate,
error rate by upstream status, latency percentiles and pool utilisation answers "is it us or
the database" without an SSH session.

The original stack could return 502 for **100 % of API traffic** while every container
reported `Up`. Liveness was measured; availability was not.

## 5. How I would prevent this in production

- **Make the contract testable.** The port mismatch is a config-to-config bug that no unit
  test catches. `verify.sh` covers it: bring the stack up in CI, assert the routes and the
  fault behaviour, fail the pipeline otherwise.
- **Never let a dependency be unbounded.** Connect, statement and command timeouts, plus
  circuit-breaking or retry budgets, belong in the client defaults, not in each call site.
- **Distinguish critical from optional dependencies** explicitly in code and in readiness.
  The cache is optional; the database is not. That decision should be visible, as it now is
  in the `cache` field of the response.
- **Health endpoints are part of the ingress contract.** A health endpoint that the load
  balancer cannot reach is not a health endpoint. Deploys should gate on readiness, not on
  "container started".
- **Validate configuration at startup and fail fast**, so a bad value is a boot failure in
  staging instead of a partial outage in production.
- **Keep runtimes supported and builds reproducible**: lockfiles, pinned and patched base
  images, an image lifecycle policy that fails a build on an EOL runtime.
- **Rehearse the failure modes.** Every fault in `verify.sh` is a chaos test. Killing the
  database or the cache on a schedule in pre-production keeps the behaviour known.
- **Least privilege and secrets by default**: no superuser application role, no credentials
  in source, resource limits on every workload.
- **Roll out progressively.** Canary the change, watch the upstream error rate, and let
  readiness plus graceful shutdown make deploys non-events.

## Appendix: reproducing the evidence

```bash
cd src/problem3
./verify.sh          # add --keep to leave the stack running
```

**22 checks, 0 failures** on the current stack: routing and the exact path and query string,
the running server reporting the `max_connections` from `init.sql` rather than the default,
which is the only proof the mount landed, the leak comparison, a cache outage degrading rather than failing, a database outage failing
fast in well under a second, a burst being shed with `Retry-After`, recovery from an upstream
IP change without a reload, and in-flight requests completing after `SIGTERM`. Each check
asserts a single property, and status, body and timing always come from the **same** request,
so a check cannot pass for the wrong reason. The timings printed are from that run on the
machine that ran it, not a published benchmark.
