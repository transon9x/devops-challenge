// Emits dist/ the way a real bundler would: content-hashed assets that can be
// cached forever, plus an index.html that must never be cached and must be
// published last.
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const dist = path.join(root, "dist");

function hash(content) {
  return crypto.createHash("sha256").update(content).digest("hex").slice(0, 12);
}

function build() {
  fs.rmSync(dist, { recursive: true, force: true });
  fs.mkdirSync(path.join(dist, "assets"), { recursive: true });

  const version = process.env.APP_VERSION || "dev";
  const app = fs
    .readFileSync(path.join(root, "src", "app.js"), "utf8")
    .replace("__APP_VERSION__", version);
  const css = fs.readFileSync(path.join(root, "src", "app.css"), "utf8");

  const appName = `app.${hash(app)}.js`;
  const cssName = `app.${hash(css)}.css`;
  fs.writeFileSync(path.join(dist, "assets", appName), app);
  fs.writeFileSync(path.join(dist, "assets", cssName), css);

  const html = fs
    .readFileSync(path.join(root, "src", "index.html"), "utf8")
    .replace("__APP_JS__", `assets/${appName}`)
    .replace("__APP_CSS__", `assets/${cssName}`)
    .replace("__APP_VERSION__", version);
  fs.writeFileSync(path.join(dist, "index.html"), html);

  // No extra files: everything under assets/ is served with a one-year immutable
  // cache, so a file with a stable name (a build manifest, say) would be pinned
  // in caches for a year. The release manifest that the pipeline writes to S3
  // already records every file, its version and its checksum.

  return { appName, cssName };
}

/* node:coverage ignore next 4 */
if (require.main === module) {
  const out = build();
  console.log(`built dist/ with ${out.appName} and ${out.cssName}`);
}

module.exports = { build, hash };
