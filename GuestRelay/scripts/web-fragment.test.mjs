// node --test: the browser guest vendored in public/web reads every fragment the invite landing
// links (public/static/invite.js browserLink and accountLink): `<payload>`, `<payload>&bind=1` and
// `<payload>&bind=1&provider=apple|google`. It loads public/web in headless Chrome, driven over
// the DevTools pipe, from a local server; every host but that server fails to resolve, so nothing
// reaches the network. Each link must give the bundle exactly the invite: the plain one connects
// to the invite's host on its relay; a bind one shows the invite for the account choice and
// connects to nothing first (this browser can't check a sign-in here).
//   CHROME=/path/to/chrome node --test scripts/web-fragment.test.mjs
// Fails on a bundle built before the landing's bind links (herdrup-desktop #543, step 6): such a
// bundle refuses `<payload>&bind=1…` as "not a herdr guest invitation".
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { accountLink, browserLink } from "../public/static/invite.js";

const PUBLIC = fileURLToPath(new URL("../public", import.meta.url));
const BUNDLE = JSON.parse(readFileSync(join(PUBLIC, "web", "manifest.json"), "utf8")).sourceCommit;
const CHROMES = ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"];
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml",
  ".png": "image/png", ".ttf": "font/ttf", ".woff2": "font/woff2", ".wasm": "application/wasm" };

const b64url = (text) => Buffer.from(text).toString("base64url");
const HOST_ID = "AAAAAAAAAAAAAAAAAAAAAA";
const PAYLOAD = b64url(JSON.stringify({
  v: 1, relay: "https://guest.herdrup.app", host_id: HOST_ID, host_pub: "B".repeat(43), invite_id: "C".repeat(22),
  secret: "D".repeat(43), machine_label: "hetzner", owner_name: "jerry", agent_name: "enyo", guest_name: "Nike",
  expires_unix: Math.floor(Date.now() / 1000) + 86400, acct: 1,
}));
const HOST_SOCKET = `wss://guest.herdrup.app/v1/guest/${HOST_ID}`;
const REVIEW = "jerry shared enyo with you";

let server, origin, chrome, profile, closedError = null;
let next = 1;
const pending = new Map();
const listeners = new Set();

function failPending(error) {
  closedError ??= error;
  for (const [id, call] of pending) {
    pending.delete(id);
    call.reject(new Error(`${call.method}: ${error.message}`));
  }
}

/** One DevTools call, on the browser or on an attached page's session. */
function send(method, params = {}, sessionId) {
  if (closedError) return Promise.reject(new Error(`${method}: ${closedError.message}`));
  if (!chrome || chrome.exitCode !== null || chrome.stdio[3].destroyed) {
    return Promise.reject(new Error(`${method}: Chrome DevTools pipe closed`));
  }
  const id = next++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, method });
    chrome.stdio[3].write(
      JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0",
      (err) => {
        if (err) failPending(err);
      },
    );
  });
}

before(async () => {
  server = createServer((req, res) => {
    const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
    let file = join(PUBLIC, path);
    // As the relay: every /web/ path that is no file gets the bundle's index.html.
    if (path.startsWith("/web/") && !(existsSync(file) && statSync(file).isFile())) file = join(PUBLIC, "web", "index.html");
    if (!file.startsWith(PUBLIC) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404).end(); return; }
    res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" }).end(readFileSync(file));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;

  const binary = process.env.CHROME ?? CHROMES.find((path) => existsSync(path));
  assert.ok(binary, `No Chrome found (looked in ${CHROMES.join(", ")}): set CHROME to a Chrome or Chromium binary.`);
  profile = mkdtempSync(join(tmpdir(), "guest-web-chrome-"));
  chrome = spawn(binary, ["--headless=new", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check",
    "--no-sandbox", `--user-data-dir=${profile}`, "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1", "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
  chrome.on("error", (err) => failPending(err));
  chrome.on("exit", (code, sig) => failPending(new Error(`Chrome exited (${sig ?? code})`)));
  chrome.stdio[3].on("error", (err) => failPending(err));
  chrome.stdio[4].on("error", (err) => failPending(err));
  chrome.stdio[4].on("close", () => failPending(new Error("Chrome DevTools pipe closed")));
  let buffered = "";
  chrome.stdio[4].on("data", (chunk) => {
    buffered += chunk.toString("utf8");
    let end;
    while ((end = buffered.indexOf("\0")) >= 0) {
      const message = JSON.parse(buffered.slice(0, end));
      buffered = buffered.slice(end + 1);
      const call = pending.get(message.id);
      if (call) {
        pending.delete(message.id);
        if (message.error) call.reject(new Error(`${call.method}: ${message.error.message}`));
        else call.resolve(message.result);
      } else for (const listener of listeners) listener(message);
    }
  });
});

after(async () => {
  try {
    if (chrome && chrome.exitCode === null) {
      await send("Browser.close").catch(() => {});
      if (chrome.exitCode === null) {
        await Promise.race([
          new Promise((resolve) => chrome.once("exit", resolve)),
          new Promise((resolve) => setTimeout(resolve, 2000)),
        ]);
      }
      if (chrome.exitCode === null) chrome.kill("SIGKILL");
    }
  } finally {
    server?.close();
    if (profile) rmSync(profile, { recursive: true, force: true });
  }
});

/** Opens origin + link in a fresh page until the bundle shows the review or a refusal, or
 *  connects to the invite's host: the page's words and the sockets it opened. */
async function open(link) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const sockets = [];
  const listener = (message) => {
    if (message.sessionId === sessionId && message.method === "Network.webSocketCreated") sockets.push(message.params.url);
  };
  listeners.add(listener);
  try {
    await send("Network.enable", {}, sessionId);
    await send("Page.navigate", { url: origin + link }, sessionId);
    let text = "";
    for (let waited = 0; waited < 15000; waited += 100) {
      await new Promise((resolve) => setTimeout(resolve, 100));
      const { result } = await send("Runtime.evaluate", { expression: "document.body ? document.body.innerText : ''", returnByValue: true }, sessionId);
      text = String(result.value ?? "");
      // Settled: the review, the welcome card's reason, or the invite's socket (and its outcome).
      if (text.includes(REVIEW) || /isn't a herdr guest invitation/i.test(text) || (sockets.includes(HOST_SOCKET) && waited >= 1000)) break;
    }
    return { text, sockets };
  } finally {
    listeners.delete(listener);
    await send("Target.closeTarget", { targetId }).catch(() => {});
  }
}

const NOT_YET = `The /web/ bundle vendored in GuestRelay/public/web (herdrup-desktop ${BUNDLE}) can't read the invite landing's ` +
  "bind links yet. Expected until herdr-app vendors the bind-aware web guest bundle (herdrup-desktop #543, account-linked " +
  "shares step 6); this test passes once that bundle is in public/web.";

test("the vendored /web/ bundle opens the plain Only this device link: it connects to the invite's host", async () => {
  const link = browserLink(PAYLOAD);
  assert.equal(link, `/web/#${PAYLOAD}`);
  const { text, sockets } = await open(link);
  assert.ok(sockets.includes(HOST_SOCKET), `${link}: no connection to ${HOST_SOCKET}; sockets ${JSON.stringify(sockets)}; page: ${text}`);
});

for (const [shape, link] of [
  // The bundle's own shape for "Add to my account" without a provider (the landing names one).
  ["<payload>&bind=1", `${browserLink(PAYLOAD)}&bind=1`],
  ["<payload>&bind=1&provider=apple", accountLink(PAYLOAD, "apple")],
  ["<payload>&bind=1&provider=google", accountLink(PAYLOAD, "google")],
]) {
  test(`the vendored /web/ bundle reads ${shape}: the invite, held for the account choice`, async () => {
    assert.ok(link.startsWith(`/web/#${PAYLOAD}&bind=1`), link);
    const { text, sockets } = await open(link);
    assert.ok(text.includes(REVIEW), `${NOT_YET}\n${shape}: the page never showed "${REVIEW}". Page: ${text}`);
    assert.ok(!sockets.includes(HOST_SOCKET), `${shape}: the bundle connected to the host before the account choice (bind=1 ignored).`);
  });
}
