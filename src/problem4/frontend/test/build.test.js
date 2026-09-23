const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { build } = require("../scripts/build.js");

test("build emits content-hashed assets and an index that references them", () => {
  const out = build();
  const dist = path.join(__dirname, "..", "dist");
  const html = fs.readFileSync(path.join(dist, "index.html"), "utf8");

  assert.match(out.appName, /^app\.[0-9a-f]{12}\.js$/);
  assert.ok(html.includes(out.appName), "index.html must reference the hashed asset");
  assert.ok(fs.existsSync(path.join(dist, "assets", out.cssName)));
});

test("identical input produces an identical asset name (cacheable forever)", () => {
  assert.strictEqual(build().appName, build().appName);
});
