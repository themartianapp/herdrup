// node --test: the bundle check passes on public/web as committed, and fails on each way a
// copy can drift from its manifest. Runs in Node, not workerd: it reads the file tree.
import assert from "node:assert/strict";
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";
import { fileURLToPath } from "node:url";
import { checkWebBundle } from "./web-bundle.mjs";

const WEB = fileURLToPath(new URL("../public/web", import.meta.url));
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
