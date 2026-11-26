// Checks the browser guest bundle in public/web against its manifest.json, written by
// herdrup-desktop's `bun run build:guest-web` (web guest contract, "Hosting"): every file
// the manifest lists is present with its SHA-256, and no other file is; every same-origin file
// its index.html links to (the icons under /static, /favicon.ico) exists in public. It also checks
// that the /web/* Content-Security-Policy in public/_headers lets the page reach exactly the relays
// the bundle's relays.json lists, so the two cannot drift. Run by `npm test`.
//   node scripts/web-bundle.mjs [--write-headers] [public/web]
// --write-headers first rewrites the wss:// sources of that policy's connect-src from relays.json.

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(join(dir, entry.name)) : [join(dir, entry.name)],
  );
}

/**
 * The ways dir differs from its manifest.json, as one line each: empty when it matches.
 * @param {string} dir
 * @returns {string[]}
 */
export function checkWebBundle(dir) {
  const manifest = JSON.parse(readFileSync(join(dir, "manifest.json"), "utf8"));
  if (typeof manifest.sourceCommit !== "string" || !/^[0-9a-f]{40}$/.test(manifest.sourceCommit)) {
    return ["manifest.json: sourceCommit is not a commit SHA"];
  }
  if (manifest.sourceDirty !== false) return ["manifest.json: built from a dirty tree"];
  const expected = new Map(Object.entries(manifest.files ?? {}));
  if (expected.size === 0) return ["manifest.json: lists no files"];

  const problems = [];
  const present = walk(dir)
    .map((path) => relative(dir, path).split(sep).join("/"))
    .filter((path) => path !== "manifest.json")
    .sort();
  for (const path of present) {
    const want = expected.get(path);
    if (want === undefined) {
      problems.push(`${path}: not in manifest.json`);
      continue;
    }
    const got = createHash("sha256").update(readFileSync(join(dir, path))).digest("hex");
    if (got !== want) problems.push(`${path}: sha256 ${got}, manifest.json says ${want}`);
  }
  const found = new Set(present);
  for (const path of expected.keys()) {
    if (!found.has(path)) problems.push(`${path}: missing`);
  }
  return problems;
}

/** One lowercase DNS name of two or more labels: no wildcard, IP literal or port. */
const RELAY_HOST = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/** A CSP source that allows WebSockets over TLS. CSP schemes are case-insensitive. */
const isWssSource = (word) => /^wss:/i.test(word);

/**
 * The WebSocket sources the /web/* policy must allow: the https origins in dir/relays.json,
 * Desktop's one list of relays, as wss:// origins in the same order. Each must be one exact
 * host: a CSP host-source with `*` would allow every host or subdomain.
 * @param {string} dir
 * @returns {string[]}
 */
export function relaySources(dir) {
  const relays = JSON.parse(readFileSync(join(dir, "relays.json"), "utf8"));
  if (!Array.isArray(relays) || relays.length === 0) {
    throw new Error("relays.json: not a non-empty list of origins");
  }
  return relays.map((relay) => {
    const url = typeof relay === "string" ? URL.parse(relay) : null;
    if (url === null || url.protocol !== "https:" || url.origin !== relay || url.port !== "" || !RELAY_HOST.test(url.hostname)) {
      throw new Error(`relays.json: ${JSON.stringify(relay)} is not an https origin of one exact host`);
    }
    return `wss://${url.hostname}`;
  });
}

/**
 * headers (a Cloudflare _headers file) with the connect-src of the /web/* block's
 * Content-Security-Policy allowing exactly sources as its wss:// sources (any case). Every other
 * source and directive is kept; the new sources take the place of the first wss:// one.
 * @param {string} headers
 * @param {string[]} sources
 * @returns {string}
 */
export function withRelaySources(headers, sources) {
  const lines = headers.split("\n");
  const block = lines.indexOf("/web/*");
  if (block < 0) throw new Error("_headers: no /web/* block");
  let at = -1;
  for (let i = block + 1; i < lines.length && /^\s+\S/.test(lines[i]); i++) {
    if (/^\s+Content-Security-Policy:/.test(lines[i])) at = i;
  }
  if (at < 0) throw new Error("_headers: the /web/* block sets no Content-Security-Policy");
  const [, name, policy] = /^(\s+Content-Security-Policy:\s*)(.*)$/.exec(lines[at]);
  let found = false;
  const directives = policy.split(";").map((directive) => {
    const words = directive.trim().split(/\s+/);
    if (words[0].toLowerCase() !== "connect-src") return directive.trim();
    found = true;
    const rest = words.slice(1);
    const first = rest.findIndex(isWssSource);
    const kept = rest.filter((word) => !isWssSource(word));
    kept.splice(first < 0 ? kept.length : first, 0, ...sources);
    return ["connect-src", ...kept].join(" ");
  });
  if (!found) throw new Error("_headers: the /web/* policy has no connect-src");
  lines[at] = name + directives.join("; ");
  return lines.join("\n");
}

/**
 * The ways headersPath's /web/* policy differs from dir/relays.json, as one line each.
 * @param {string} dir
 * @param {string} headersPath
 * @returns {string[]}
 */
export function checkRelayHeaders(dir, headersPath) {
  try {
    const headers = readFileSync(headersPath, "utf8");
    if (withRelaySources(headers, relaySources(dir)) === headers) return [];
    return ["_headers: the /web/* connect-src wss:// sources differ from relays.json (run with --write-headers)"];
  } catch (error) {
    return [error.message];
  }
}

/**
 * The files that dir/index.html links to on the relay's own origin but outside the bundle
 * (the tab icon, Open Graph image: /static/*, /favicon.ico) are served from dir's parent, the
 * Worker's public directory, which the manifest does not cover. One line per link whose file is
 * not there: a root-relative src, href or content value, or one on a relays.json origin.
 * @param {string} dir
 * @returns {string[]}
 */
export function checkSiteAssets(dir) {
  const html = readFileSync(join(dir, "index.html"), "utf8");
  const origins = new Set(relaySources(dir).map((source) => source.replace(/^wss:/, "https:")));
  const publicDir = join(dir, "..");
  const problems = [];
  for (const [, value] of html.matchAll(/\b(?:src|href|content)\s*=\s*["']([^"']*)["']/gi)) {
    let path;
    if (value.startsWith("/") && !value.startsWith("//")) path = new URL(value, "https://relay.invalid").pathname;
    else {
      const url = URL.parse(value);
      if (url === null || !origins.has(url.origin)) continue;
      path = url.pathname;
    }
    const file = decodeURIComponent(path).replace(/\/$/, "/index.html");
    if (!existsSync(join(publicDir, file))) problems.push(`index.html: ${value} is not in public${file}`);
  }
  return problems;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const write = args[0] === "--write-headers";
  const dir = (write ? args[1] : args[0]) ?? fileURLToPath(new URL("../public/web", import.meta.url));
  const headersPath = join(dir, "..", "_headers");
  if (write) {
    writeFileSync(headersPath, withRelaySources(readFileSync(headersPath, "utf8"), relaySources(dir)));
  }
  const problems = [...checkWebBundle(dir), ...checkRelayHeaders(dir, headersPath), ...checkSiteAssets(dir)];
  for (const problem of problems) console.error(problem);
  if (problems.length > 0) process.exit(1);
  console.log("public/web matches manifest.json, its same-origin links exist, and _headers allows the relays in relays.json");
}
