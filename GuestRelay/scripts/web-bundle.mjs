// Checks the browser guest bundle in public/web against its manifest.json, written by
// herdrup-desktop's `bun run build:guest-web` (web guest contract, "Hosting"): every file
// the manifest lists is present with its SHA-256, and no other file is. Run by `npm test`.
//   node scripts/web-bundle.mjs [public/web]

import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
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

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = process.argv[2] ?? fileURLToPath(new URL("../public/web", import.meta.url));
  const problems = checkWebBundle(dir);
  for (const problem of problems) console.error(problem);
  if (problems.length > 0) process.exit(1);
  console.log("public/web matches manifest.json");
}
