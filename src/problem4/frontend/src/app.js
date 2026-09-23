const VERSION = "__APP_VERSION__";
const app = document.getElementById("app");
app.textContent = `Trading Console (${VERSION})`;

fetch("/config.json", { cache: "no-store" })
  .then((response) => (response.ok ? response.json() : {}))
  .then((config) => {
    if (config.apiBaseUrl) {
      app.dataset.apiBaseUrl = config.apiBaseUrl;
    }
  })
  .catch(() => {});
