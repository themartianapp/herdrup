// Opt-in crash and hang reports from the HerdrUp app (owner decision 2026-11-13). The app
// sends one only while its "Share anonymous usage count" switch is on: MetricKit's crash or
// hang diagnostic reduced to the app version and build, OS, device model, exception, the
// termination reason or hang duration, and each thread's stack as binary names, UUIDs and
// offsets. Each accepted report is re-serialized from the validated fields alone and stored
// as one R2 object; the bucket's lifecycle rule deletes it after 90 days. Nothing about a
// report is logged: not its body, IP, headers or outcome. Only a missing binding or an
// internal error logs, and then only endpoint and outcome.
//
// The reports are read back by Tools/crash/symbolicate.py through the two admin GETs, which
// need `Authorization: Bearer <CRASH_ADMIN_TOKEN>` (a Worker secret). Without the secret both
// are 404, as if they did not exist.
import { errorResponse, json, log, readCapped, type Env } from "./relay";

/** Largest report body. The app trims a report's stacks to fit. */
export const MAX_CRASH_BYTES = 65_536;
/** As many binaries as frames: at worst each frame names a binary of its own. */
export const MAX_BINARIES = 8_192;
export const MAX_STACKS = 1_024;
export const MAX_FRAMES_PER_STACK = 512;
export const MAX_FRAMES = 8_192;
/** Objects listed per admin page. */
const LIST_LIMIT = 500;

const REQUIRED_KEYS = ["binaries", "build", "device", "kind", "os", "stacks", "v", "version"];
const OPTIONAL_KEYS: Record<CrashKind, string[]> = {
  crash: ["exception", "termination", "truncated"],
  hang: ["hangSeconds", "truncated"],
};
const EXCEPTION_KEYS = ["code", "signal", "type"];
const VERSION_OR_BUILD = /^[0-9A-Za-z._-]{1,32}$/;
const DEVICE = /^[0-9A-Za-z,._-]{1,32}$/;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
/** Printable ASCII, no leading or trailing space. */
const printable = (max: number) => new RegExp(`^[\\x21-\\x7e](?:[\\x20-\\x7e]{0,${max - 2}}[\\x21-\\x7e])?$`);
const OS = printable(64);
const BINARY_NAME = printable(128);
const TERMINATION = printable(512);
/** A stored report's key: `v1/<UTC day>/<version>-<build>/<kind>-<random>.json`. */
const REPORT_KEY = /^v1\/\d{4}-\d{2}-\d{2}\/[0-9A-Za-z._-]{1,32}-[0-9A-Za-z._-]{1,32}\/(?:crash|hang)-[A-Za-z0-9_-]{22}\.json$/;
const REPORT_PATH = /^\/v1\/crash\/reports\/(.+)$/;
const LIST_PREFIX = /^v1\/[0-9A-Za-z._\/-]{0,96}$/;

type CrashKind = "crash" | "hang";

export interface CrashReport {
  v: 1;
  kind: CrashKind;
  version: string;
  build: string;
  os: string;
  device: string;
  exception?: { type?: number; code?: number; signal?: number };
  termination?: string;
  hangSeconds?: number;
  truncated?: true;
  binaries: { name: string; uuid: string }[];
  stacks: { attributed: boolean; frames: [number, number][] }[];
}

/** `POST /v1/crash`, and the admin `GET /v1/crash/reports[/<key>]`. */
export async function handleCrash(request: Request, env: Env, pathname: string): Promise<Response> {
  const endpoint = "/v1/crash";
  const report = pathname === "/v1/crash";
  if (report && request.method !== "POST") return errorResponse(405, "method_not_allowed", { Allow: "POST" });
  if (!report && request.method !== "GET") return errorResponse(404, "not_found");
  try {
    // The admin reads are bearer-only: the token is 32+ random characters, and listing a
    // day's reports must not spend a sender's budget.
    if (!report) return await handleAdmin(request, env, pathname);
    if (env.CRASH_LIMIT === undefined || env.CRASHES === undefined) {
      log({ endpoint, outcome: "not_configured" });
      return errorResponse(500, "not_configured");
    }
    // Its own per-IP budget, checked before the body is read, so reports never spend the
    // ping, host or guest limits.
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.CRASH_LIMIT.limit({ key: ip })).success) return errorResponse(429, "rate_limited");

    const body = await readCapped(request, MAX_CRASH_BYTES);
    if (body === null) return errorResponse(413, "too_large");
    const parsed = parseCrash(body);
    if (parsed === null) return errorResponse(400, "bad_request");
    await env.CRASHES.put(reportKey(parsed, new Date()), JSON.stringify(parsed), {
      httpMetadata: { contentType: "application/json" },
    });
    return new Response(null, { status: 204 });
  } catch {
    // The error itself is deliberately not logged: it may echo request content.
    log({ endpoint, outcome: "internal_error" });
    return errorResponse(500, "internal_error");
  }
}

/** `v1/<UTC day>/<version>-<build>/<kind>-<16 random bytes, b64url>.json`. */
export function reportKey(report: CrashReport, now: Date): string {
  const random = crypto.getRandomValues(new Uint8Array(16));
  let raw = "";
  for (const byte of random) raw += String.fromCharCode(byte);
  const id = btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `v1/${now.toISOString().slice(0, 10)}/${report.version}-${report.build}/${report.kind}-${id}.json`;
}

/** The admin reads. 404 unless CRASH_ADMIN_TOKEN and the bucket are set; 401 for any other bearer. */
async function handleAdmin(request: Request, env: Env, pathname: string): Promise<Response> {
  const token = env.CRASH_ADMIN_TOKEN;
  const crashes = env.CRASHES;
  if (token === undefined || token.length < 32 || crashes === undefined) return errorResponse(404, "not_found");
  const given = /^Bearer (\S+)$/.exec(request.headers.get("Authorization") ?? "")?.[1] ?? "";
  if (!(await sameSecret(given, token))) return errorResponse(401, "unauthorized");

  if (pathname === "/v1/crash/reports") {
    const params = new URL(request.url).searchParams;
    const prefix = params.get("prefix") ?? "v1/";
    if (!LIST_PREFIX.test(prefix)) return errorResponse(400, "bad_request");
    const cursor = params.get("cursor") ?? undefined;
    const listed = await crashes.list({ prefix, cursor, limit: LIST_LIMIT });
    return json(200, {
      keys: listed.objects.map((object) => ({ key: object.key, size: object.size, uploaded: object.uploaded.toISOString() })),
      cursor: listed.truncated ? listed.cursor : null,
    }, { "Cache-Control": "no-store" });
  }
  const key = REPORT_PATH.exec(pathname)?.[1];
  if (key === undefined || !REPORT_KEY.test(key)) return errorResponse(404, "not_found");
  const object = await crashes.get(key);
  if (object === null) return errorResponse(404, "not_found");
  return new Response(object.body, { headers: { "content-type": "application/json", "Cache-Control": "no-store" } });
}

/** Constant-time comparison of the bearer and the secret, through their SHA-256. */
async function sameSecret(given: string, secret: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(secret)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

/** The report, rebuilt from its validated fields, or null unless the body is exactly the schema. */
export function parseCrash(body: ArrayBuffer): CrashReport | null {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(body));
  } catch {
    return null;
  }
  if (!isObject(value)) return null;
  const { v, kind, version, build, os, device, exception, termination, hangSeconds, truncated, binaries, stacks } = value;
  if (v !== 1 || (kind !== "crash" && kind !== "hang")) return null;
  const keys = Object.keys(value);
  if (!REQUIRED_KEYS.every((key) => keys.includes(key))) return null;
  if (!keys.every((key) => REQUIRED_KEYS.includes(key) || OPTIONAL_KEYS[kind].includes(key))) return null;
  if (!isString(version, VERSION_OR_BUILD) || !isString(build, VERSION_OR_BUILD)) return null;
  if (!isString(os, OS) || !isString(device, DEVICE)) return null;
  if (truncated !== undefined && truncated !== true) return null;

  const report: CrashReport = { v: 1, kind, version, build, os, device, binaries: [], stacks: [] };
  if (exception !== undefined) {
    if (!isObject(exception)) return null;
    const entries = Object.entries(exception);
    if (entries.length === 0 || !entries.every(([key, n]) => EXCEPTION_KEYS.includes(key) && Number.isSafeInteger(n))) return null;
    report.exception = Object.fromEntries(entries.sort(([a], [b]) => (a < b ? -1 : 1)));
  }
  if (termination !== undefined) {
    if (!isString(termination, TERMINATION)) return null;
    report.termination = termination;
  }
  if (hangSeconds !== undefined) {
    if (typeof hangSeconds !== "number" || !(hangSeconds >= 0 && hangSeconds <= 86_400)) return null;
    report.hangSeconds = hangSeconds;
  }
  if (truncated === true) report.truncated = true;

  if (!Array.isArray(binaries) || binaries.length > MAX_BINARIES) return null;
  for (const binary of binaries) {
    if (!isObject(binary) || Object.keys(binary).sort().join() !== "name,uuid") return null;
    if (!isString(binary.name, BINARY_NAME) || !isString(binary.uuid, UUID)) return null;
    report.binaries.push({ name: binary.name, uuid: binary.uuid });
  }
  if (!Array.isArray(stacks) || stacks.length > MAX_STACKS) return null;
  let total = 0;
  for (const stack of stacks) {
    if (!isObject(stack) || Object.keys(stack).sort().join() !== "attributed,frames") return null;
    const { attributed, frames } = stack;
    if (typeof attributed !== "boolean" || !Array.isArray(frames)) return null;
    if (frames.length === 0 || frames.length > MAX_FRAMES_PER_STACK) return null;
    total += frames.length;
    if (total > MAX_FRAMES) return null;
    const kept: [number, number][] = [];
    for (const frame of frames) {
      if (!Array.isArray(frame) || frame.length !== 2) return null;
      const [binary, offset] = frame;
      if (!Number.isSafeInteger(binary) || binary < 0 || binary >= report.binaries.length) return null;
      if (!Number.isSafeInteger(offset) || offset < 0) return null;
      kept.push([binary, offset]);
    }
    report.stacks.push({ attributed, frames: kept });
  }
  return report;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isString(value: unknown, pattern: RegExp): value is string {
  return typeof value === "string" && pattern.test(value);
}
