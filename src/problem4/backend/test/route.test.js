const assert = require("node:assert");
const { test } = require("node:test");
const { route } = require("../src/server.js");

test("health endpoint reports ok", () => {
  const res = route({ url: "/health" });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.status, "ok");
});

test("api endpoint responds", () => {
  assert.strictEqual(route({ url: "/api/hello" }).status, 200);
});

test("unknown path is a 404", () => {
  assert.strictEqual(route({ url: "/nope" }).status, 404);
});
