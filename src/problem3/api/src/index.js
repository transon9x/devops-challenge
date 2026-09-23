const crypto = require("node:crypto");
const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

function log(level, msg, extra = {}) {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), level, msg, ...extra }) + "\n"
  );
}

function required(name) {
  const value = process.env[name];
  if (!value) {
    log("error", "missing required environment variable", { variable: name });
    process.exit(1);
  }
  return value;
}

// A malformed number is a configuration bug: fail at startup with the variable named,
// rather than running with NaN, 0 or a negative timeout that only shows up under load.
function num(name, fallback, { min, max }) {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isFinite(value) || !Number.isInteger(value) || value < min || value > max) {
    log("error", "invalid numeric environment variable", {
      variable: name,
      value: raw,
      expected: `integer in [${min}, ${max}]`,
    });
    process.exit(1);
  }
  return value;
}

const PORT = num("PORT", 3000, { min: 1, max: 65535 });
const SHUTDOWN_GRACE_MS = num("SHUTDOWN_GRACE_MS", 10000, { min: 100, max: 120000 });
// 0 in every normal configuration. verify.sh sets it so that requests are still
// in flight when SIGTERM arrives, which is the only way to prove draining works.
const DRAIN_TEST_DELAY_MS = num("DRAIN_TEST_DELAY_MS", 0, { min: 0, max: 60000 });
const DB_POOL_MAX = num("DB_POOL_MAX", 8, { min: 1, max: 100 });
// The pool bounds queries; this bounds the queue in front of it. Without it a burst waits
// in memory until every acquisition times out, which turns a spike into a wall of 503s
// several seconds late instead of immediate, cheap backpressure.
const MAX_INFLIGHT = num("MAX_INFLIGHT", DB_POOL_MAX * 2, { min: 1, max: 10000 });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const pool = new Pool({
  host: required("DB_HOST"),
  port: num("DB_PORT", 5432, { min: 1, max: 65535 }),
  user: required("DB_USER"),
  password: required("DB_PASSWORD"),
  database: required("DB_NAME"),
  max: DB_POOL_MAX,
  connectionTimeoutMillis: num("DB_CONNECT_TIMEOUT_MS", 2000, { min: 100, max: 60000 }),
  idleTimeoutMillis: 10000,
  statement_timeout: num("DB_STATEMENT_TIMEOUT_MS", 5000, { min: 100, max: 60000 }),
  query_timeout: num("DB_QUERY_TIMEOUT_MS", 5000, { min: 100, max: 60000 }),
});

pool.on("error", (err) => {
  log("error", "postgres pool error on idle client", { error: err.message });
});

const redis = new Redis({
  host: required("REDIS_HOST"),
  port: num("REDIS_PORT", 6379, { min: 1, max: 65535 }),
  connectTimeout: num("REDIS_CONNECT_TIMEOUT_MS", 1000, { min: 100, max: 30000 }),
  commandTimeout: num("REDIS_COMMAND_TIMEOUT_MS", 500, { min: 50, max: 30000 }),
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
  retryStrategy: (attempt) => Math.min(attempt * 200, 5000),
});

redis.on("error", (err) => {
  log("warn", "redis error", { error: err.message });
});

const app = express();
app.disable("x-powered-by");

app.use((req, res, next) => {
  req.requestId = req.headers["x-request-id"] || crypto.randomUUID();
  res.setHeader("X-Request-Id", req.requestId);
  next();
});

let inflight = 0;
let shed = 0;

// Bounded queue: reject immediately rather than accumulating waiters in memory.
app.use("/api", (req, res, next) => {
  if (inflight >= MAX_INFLIGHT) {
    shed += 1;
    log("warn", "shedding request, in-flight cap reached", {
      request_id: req.requestId,
      inflight,
      max_inflight: MAX_INFLIGHT,
    });
    res.setHeader("Retry-After", "1");
    return res
      .status(503)
      .json({ ok: false, error: "overloaded", request_id: req.requestId });
  }
  inflight += 1;
  // `close` fires on a normal finish and on an aborted connection, so the counter
  // cannot leak the way a `finish`-only handler would.
  res.once("close", () => {
    inflight -= 1;
  });
  return next();
});

app.get("/api/users", async (req, res) => {
  if (DRAIN_TEST_DELAY_MS > 0) {
    await sleep(DRAIN_TEST_DELAY_MS);
  }

  let dbRows;
  try {
    const result = await pool.query("SELECT NOW()");
    dbRows = result.rows[0];
  } catch (err) {
    log("error", "database query failed", {
      request_id: req.requestId,
      error: err.message,
    });
    return res
      .status(503)
      .json({ ok: false, error: "database_unavailable", request_id: req.requestId });
  }

  let cache = "ok";
  try {
    await redis.set("last_call", Date.now(), "EX", 300);
  } catch (err) {
    cache = "degraded";
    log("warn", "cache write failed, serving without cache", {
      request_id: req.requestId,
      error: err.message,
    });
  }

  return res.json({ ok: true, time: dbRows, cache, request_id: req.requestId });
});

// A proxy that mangles the path or drops the query string is the classic nginx bug, so
// this endpoint makes exactly what arrived visible. verify.sh asserts against it.
app.get("/api/echo", (req, res) => {
  res.json({
    ok: true,
    original_url: req.originalUrl,
    query: req.query,
    request_id: req.requestId,
  });
});

app.get(["/status", "/live"], (req, res) => {
  res.json({ status: "ok" });
});

app.get("/ready", async (req, res) => {
  const checks = {};

  try {
    await pool.query("SELECT 1");
    checks.postgres = "ok";
  } catch (err) {
    checks.postgres = "fail";
    checks.postgres_error = err.message;
  }

  try {
    await redis.ping();
    checks.redis = "ok";
  } catch (err) {
    checks.redis = "degraded";
  }

  const ready = checks.postgres === "ok";
  res.status(ready ? 200 : 503).json({
    ready,
    checks,
    load: { inflight, max_inflight: MAX_INFLIGHT, shed_total: shed },
  });
});

const server = app.listen(PORT, () =>
  log("info", "api listening", { port: PORT })
);

let shuttingDown = false;

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", "shutdown started", { signal });

  const forced = setTimeout(() => {
    log("error", "shutdown grace period exceeded, exiting");
    process.exit(1);
  }, SHUTDOWN_GRACE_MS);
  forced.unref();

  server.close(async () => {
    log("info", "http server closed, draining dependencies");
    await pool.end().catch((err) =>
      log("warn", "pool drain failed", { error: err.message })
    );
    await redis.quit().catch(() => redis.disconnect());
    clearTimeout(forced);
    log("info", "shutdown complete");
    process.exit(0);
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
