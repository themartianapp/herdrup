// node --test: the bundle check passes on public/web as committed, and fails on each way a
// copy can drift from its manifest; public/_headers allows exactly the relays in relays.json;
// the same-origin files index.html links to exist in public.
// Runs in Node, not workerd: it reads the file tree.
import assert from "node:assert/strict";
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { checkRelayHeaders, checkSiteAssets, checkWebBundle, relaySources, withRelaySources } from "./web-bundle.mjs";

const WEB = fileURLToPath(new URL("../public/web", import.meta.url));
const HEADERS = fileURLToPath(new URL("../public/_headers", import.meta.url));
let copy;

beforeEach(() => {
  copy = mkdtempSync(join(tmpdir(), "guest-web-"));
  cpSync(WEB, copy, { recursive: true });
});

afterEach(() => rmSync(copy, { recursive: true, force: true }));

test("public/web matches its manifest.json", () => {
  assert.deepEqual(checkWebBundle(WEB), []);
  assert.deepEqual(checkWebBundle(copy), []);
});

test("a changed file fails the check", () => {
  appendFileSync(join(copy, "index.html"), "<script>alert(1)</script>");
  const problems = checkWebBundle(copy);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /^index\.html: sha256 [0-9a-f]{64}, manifest\.json says [0-9a-f]{64}$/);
});

test("an extra file fails the check", () => {
  writeFileSync(join(copy, "assets", "extra.js"), "");
  assert.deepEqual(checkWebBundle(copy), ["assets/extra.js: not in manifest.json"]);
});

test("a missing file fails the check", () => {
  unlinkSync(join(copy, "index.html"));
  assert.deepEqual(checkWebBundle(copy), ["index.html: missing"]);
});

test("a manifest without a clean source commit fails the check", () => {
  const manifest = JSON.parse(readFileSync(join(WEB, "manifest.json"), "utf8"));
  writeFileSync(join(copy, "manifest.json"), JSON.stringify({ ...manifest, sourceDirty: true }));
  assert.deepEqual(checkWebBundle(copy), ["manifest.json: built from a dirty tree"]);
  writeFileSync(join(copy, "manifest.json"), JSON.stringify({ ...manifest, sourceCommit: "main" }));
  assert.deepEqual(checkWebBundle(copy), ["manifest.json: sourceCommit is not a commit SHA"]);
});

test("public/_headers allows exactly the relays in relays.json", () => {
  assert.deepEqual(checkRelayHeaders(WEB, HEADERS), []);
});

test("a relay added to relays.json fails the check until _headers is rewritten", () => {
  const relays = JSON.parse(readFileSync(join(copy, "relays.json"), "utf8"));
  writeFileSync(join(copy, "relays.json"), JSON.stringify([...relays, "https://relay.example.com"]));
  assert.deepEqual(checkRelayHeaders(copy, HEADERS), [
    "_headers: the /web/* connect-src wss:// sources differ from relays.json (run with --write-headers)",
  ]);

  const headers = join(copy, "_headers");
  writeFileSync(headers, withRelaySources(readFileSync(HEADERS, "utf8"), relaySources(copy)));
  assert.deepEqual(checkRelayHeaders(copy, headers), []);
  const lines = readFileSync(headers, "utf8").split("\n");
  const policy = lines.slice(lines.indexOf("/web/*")).find((line) => line.includes("connect-src"));
  const connect = policy.split(";").find((directive) => directive.trim().startsWith("connect-src"));
  assert.deepEqual(connect.trim().split(" "), [
    "connect-src",
    "'self'",
    ...relays.map((relay) => relay.replace("https://", "wss://")),
    "wss://relay.example.com",
    "https://accounts.herdrup.app",
  ]);
});

test("a relay removed from relays.json leaves _headers allowing it, which fails the check", () => {
  const relays = JSON.parse(readFileSync(join(copy, "relays.json"), "utf8"));
  writeFileSync(join(copy, "relays.json"), JSON.stringify(relays.slice(0, 1)));
  assert.equal(checkRelayHeaders(copy, HEADERS).length, 1);
});

test("relays.json must list https origins of one exact host only", () => {
  const bad = [
    [],
    ["wss://guest.herdrup.app"],
    ["https://guest.herdrup.app/"],
    ["https://guest.herdrup.app/x"],
    [7],
    ["https://*"],
    ["https://*.evil.example"],
    ["https://*:8443"],
    ["https://guest.herdrup.app:8443"],
    ["https://192.0.2.1"],
    ["https://[::1]"],
    ["https://localhost"],
  ];
  for (const relays of bad) {
    writeFileSync(join(copy, "relays.json"), JSON.stringify(relays));
    assert.throws(() => relaySources(copy), /^Error: relays\.json: /, JSON.stringify(relays));
  }
});

test("a wss source in any case outside relays.json fails the check and is removed on rewrite", () => {
  const headers = readFileSync(HEADERS, "utf8").replace(
    "wss://guest.herdrup.themartian.app",
    "wss://guest.herdrup.themartian.app WSS://evil.example",
  );
  const path = join(copy, "_headers");
  writeFileSync(path, headers);
  assert.equal(checkRelayHeaders(WEB, path).length, 1);
  const rewritten = withRelaySources(headers, relaySources(WEB));
  assert.ok(!/evil\.example/i.test(rewritten));
  assert.equal(rewritten, readFileSync(HEADERS, "utf8"));
});

/** A copy of all of public (bundle plus the Worker's own files), with its web directory. */
function publicCopy() {
  const root = join(copy, "public");
  cpSync(fileURLToPath(new URL("../public", import.meta.url)), root, { recursive: true });
  return join(root, "web");
}

test("every same-origin file index.html links to exists in public", () => {
  assert.deepEqual(checkSiteAssets(WEB), []);
});

test("a root-relative icon missing from public fails the check", () => {
  const web = publicCopy();
  unlinkSync(join(web, "..", "static", "apple-touch-icon.png"));
  assert.deepEqual(checkSiteAssets(web), [
    "index.html: /static/apple-touch-icon.png is not in public/static/apple-touch-icon.png",
  ]);
});

test("an absolute link on a relay origin is checked; other origins are not", () => {
  const web = publicCopy();
  const html = readFileSync(join(web, "index.html"), "utf8").replace(
    "</head>",
    '<meta property="og:x" content="https://guest.herdrup.themartian.app/static/gone.png">' +
      '<link rel="preconnect" href="https://fonts.example.com/static/gone.png"></head>',
  );
  writeFileSync(join(web, "index.html"), html);
  assert.deepEqual(checkSiteAssets(web), [
    "index.html: https://guest.herdrup.themartian.app/static/gone.png is not in public/static/gone.png",
  ]);
});
