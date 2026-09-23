// Demonstrates the connection leak that the original handler had, and that the
// fixed pattern does not leak. Run against the running Postgres service:
//
//   docker compose run --rm --no-deps -v "$PWD/tests:/app/tests:ro" api \
//     node tests/pool-leak-demo.js
//
// Exits 0 only if the buggy pattern exhausts its pool AND the fixed pattern
// stays usable after the same number of failing queries.

const { Pool } = require("pg");

const BAD_QUERY = "SELECT * FROM table_that_does_not_exist";
const POOL_MAX = 5;
const ATTEMPTS = 8;

const base = {
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: POOL_MAX,
  connectionTimeoutMillis: 1500,
};

const isPoolTimeout = (err) =>
  /timeout exceeded when trying to connect/i.test(err.message);

// Original code path: release() is only reached when the query succeeds.
async function buggyPattern() {
  const pool = new Pool(base);
  pool.on("error", () => {});
  let queryErrors = 0;
  let exhaustedAtAttempt = null;

  for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
    try {
      const client = await pool.connect();
      await client.query(BAD_QUERY);
      client.release();
    } catch (err) {
      if (isPoolTimeout(err)) {
        exhaustedAtAttempt = attempt;
        break;
      }
      queryErrors += 1;
    }
  }

  // pool.end() would hang forever here: the leaked clients are never returned.
  return { pattern: "connect/query/release", queryErrors, exhaustedAtAttempt };
}

// Fixed code path: pool.query() always returns the client to the pool.
async function fixedPattern() {
  const pool = new Pool(base);
  pool.on("error", () => {});
  let queryErrors = 0;
  let exhaustedAtAttempt = null;

  for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
    try {
      await pool.query(BAD_QUERY);
    } catch (err) {
      if (isPoolTimeout(err)) {
        exhaustedAtAttempt = attempt;
        break;
      }
      queryErrors += 1;
    }
  }

  let stillUsable = false;
  try {
    const result = await pool.query("SELECT 1 AS ok");
    stillUsable = result.rows[0].ok === 1;
  } catch (err) {
    stillUsable = false;
  }

  await pool.end();
  return { pattern: "pool.query", queryErrors, exhaustedAtAttempt, stillUsable };
}

(async () => {
  const buggy = await buggyPattern();
  const fixed = await fixedPattern();

  const proven =
    buggy.exhaustedAtAttempt !== null &&
    fixed.exhaustedAtAttempt === null &&
    fixed.stillUsable === true;

  process.stdout.write(
    JSON.stringify({ pool_max: POOL_MAX, attempts: ATTEMPTS, buggy, fixed, proven }, null, 2) +
      "\n"
  );
  process.exit(proven ? 0 : 1);
})();
