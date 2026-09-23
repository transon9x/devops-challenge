const http = require("node:http");

const PORT = Number(process.env.PORT || 3000);
const VERSION = process.env.APP_VERSION || "dev";

function route(req) {
  if (req.url === "/health") {
    return { status: 200, body: { status: "ok", version: VERSION } };
  }
  if (req.url === "/api/hello") {
    return { status: 200, body: { message: "hello", version: VERSION } };
  }
  return { status: 404, body: { error: "not_found" } };
}

const server = http.createServer((req, res) => {
  const { status, body } = route(req);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
});

/* node:coverage ignore next 4 */
if (require.main === module) {
  server.listen(PORT, () => console.log(`backend listening on ${PORT}`));
  process.on("SIGTERM", () => server.close(() => process.exit(0)));
}

module.exports = { route, server };
