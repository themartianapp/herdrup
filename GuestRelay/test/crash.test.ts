import { SELF, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// POST /v1/crash and its admin reads, against the real Worker, R2 bucket and rate limits in
// workerd. Each test sends from its own IPs, so the per-IP limits never collide.

const ORIGIN = "https://guest.herdrup.app";
const ADMIN = "test-admin-token-0123456789abcdefghijklmnop";
const UUID_A = "913AE206-9644-328F-9952-176ECA385CA0";
const UUID_B = "1539FAA7-31DA-3C41-B1B4-AA9691063824";

let ipCounter = 0;
const freshIp = () => `2001:db8:c::${(++ipCounter).toString(16)}`;

const validCrash = (fields: Record<string, unknown> = {}) => ({
  v: 1,
  kind: "crash",
  version: "1.3.4",
  build: "245",
  os: "iPhone OS 27.2 (24C101)",
  device: "iPhone19,4",
  exception: { code: 0, signal: 6, type: 10 },
  termination: "Namespace SIGNAL, Code 6 Abort trap: 6",
  binaries: [
    { name: "Herdr", uuid: UUID_A },
    { name: "libswiftCore.dylib", uuid: UUID_B },
  ],
  stacks: [
    { attributed: true, frames: [[1, 20596], [0, 740520], [0, 3347124]] },
    { attributed: false, frames: [[1, 4096]] },
  ],
  ...fields,
});

const validHang = (fields: Record<string, unknown> = {}) => {
  const { exception: _e, termination: _t, ...rest } = validCrash();
  return { ...rest, kind: "hang", hangSeconds: 4.25, ...fields };
};

function crash(body: unknown, ip = freshIp(), method = "POST", headers: Record<string, string> = {}): Promise<Response> {
  const raw = typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body);
  return SELF.fetch(`${ORIGIN}/v1/crash`, {
    method,
    headers: { "CF-Connecting-IP": ip, "Content-Type": "application/json", ...headers },
    body: method === "GET" ? undefined : raw,
  });
}

function admin(path: string, token: string | null = ADMIN, method = "GET"): Promise<Response> {
  return SELF.fetch(`${ORIGIN}${path}`, {
    method,
    headers: { "CF-Connecting-IP": freshIp(), ...(token === null ? {} : { Authorization: `Bearer ${token}` }) },
  });
}

async function expectError(response: Response, status: number, code: string): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.headers.get("X-Herdr-Guest-Error")).toBe(code);
  expect(await response.json()).toEqual({ error: code });
}

async function storedKeys(): Promise<string[]> {
  return (await env.CRASHES.list({ prefix: "v1/" })).objects.map((object) => object.key);
}

async function clearBucket(): Promise<void> {
  const keys = await storedKeys();
  if (keys.length > 0) await env.CRASHES.delete(keys);
}

describe("crash reports", () => {
  beforeEach(clearBucket);

  it("stores an accepted report as one object, rebuilt from its fields alone", async () => {
    const ip = "198.51.100.77";
    const response = await crash(validCrash(), ip, "POST", { "User-Agent": "Herdr/245 CFNetwork", "CF-IPCountry": "IT" });
    expect(response.status).toBe(204);
    const keys = await storedKeys();
    expect(keys).toHaveLength(1);
    const day = new Date().toISOString().slice(0, 10);
    expect(keys[0]).toMatch(new RegExp(`^v1/${day}/1\\.3\\.4-245/crash-[A-Za-z0-9_-]{22}\\.json$`));
    const object = await env.CRASHES.get(keys[0]);
    expect(object).not.toBeNull();
    expect(object!.customMetadata).toEqual({});
    expect(object!.httpMetadata?.contentType).toBe("application/json");
    const stored = await object!.text();
    expect(JSON.parse(stored)).toEqual(validCrash());
    // Neither the IP, the user agent nor the country is kept.
    for (const text of [ip, "CFNetwork", "IT\""]) expect(stored).not.toContain(text);
  });

  it("stores a hang report, and a truncated one", async () => {
    expect((await crash(validHang())).status).toBe(204);
    expect((await crash(validCrash({ truncated: true, stacks: [] }))).status).toBe(204);
    const keys = await storedKeys();
    expect(keys.filter((key) => key.includes("/hang-"))).toHaveLength(1);
    expect(keys.filter((key) => key.includes("/crash-"))).toHaveLength(1);
  });

  it("takes the optional crash fields away and still accepts", async () => {
    const { exception: _e, termination: _t, ...minimal } = validCrash();
    expect((await crash(minimal)).status).toBe(204);
    expect((await crash(validCrash({ exception: { signal: 11 } }))).status).toBe(204);
  });

  it("refuses anything but the exact schema with 400 and stores nothing", async () => {
    const { device: _d, ...noDevice } = validCrash();
    const { stacks: _s, ...noStacks } = validCrash();
    const bodies: unknown[] = [
      validCrash({ v: 2 }),
      validCrash({ kind: "jetsam" }),
      validCrash({ agent: "claude" }),
      validCrash({ regionFormat: "IT" }),
      validCrash({ exceptionReason: { composedMessage: "secret text" } }),
      validCrash({ hangSeconds: 3 }),
      validHang({ termination: "Namespace SIGNAL" }),
      validHang({ hangSeconds: -1 }),
      validHang({ hangSeconds: "20 sec" }),
      noDevice,
      noStacks,
      validCrash({ version: "1.3 beta" }),
      validCrash({ build: "" }),
      validCrash({ device: "iPhone 19 Pro" }),
      validCrash({ os: "x".repeat(65) }),
      validCrash({ os: " iPhone OS" }),
      validCrash({ termination: "line one\nline two" }),
      validCrash({ termination: "é" }),
      validCrash({ termination: "t".repeat(513) }),
      validCrash({ exception: {} }),
      validCrash({ exception: { type: 10, reason: 1 } }),
      validCrash({ exception: { type: 1.5 } }),
      validCrash({ truncated: false }),
      validCrash({ binaries: [{ name: "Herdr", uuid: UUID_A.toLowerCase() }] , stacks: [] }),
      validCrash({ binaries: [{ name: "Herdr", uuid: UUID_A, path: "/private/var/x" }], stacks: [] }),
      validCrash({ binaries: [{ name: "", uuid: UUID_A }], stacks: [] }),
      validCrash({ stacks: [{ attributed: true, frames: [[2, 1]] }] }),
      validCrash({ stacks: [{ attributed: true, frames: [[0, -1]] }] }),
      validCrash({ stacks: [{ attributed: true, frames: [[0, 1.5]] }] }),
      validCrash({ stacks: [{ attributed: true, frames: [[0, 1, 2]] }] }),
      validCrash({ stacks: [{ attributed: true, frames: [] }] }),
      validCrash({ stacks: [{ attributed: "yes", frames: [[0, 1]] }] }),
      validCrash({ stacks: [{ attributed: true, frames: [[0, 1]], thread: "main" }] }),
      validCrash({ stacks: [{ attributed: true, frames: Array(513).fill([0, 1]) }] }),
      [validCrash()],
      "null",
      "",
      "not json",
      `${JSON.stringify(validCrash())}x`,
      new Uint8Array([0x7b, 0xff, 0x7d]),
    ];
    for (const body of bodies) await expectError(await crash(body), 400, "bad_request");
    expect(await storedKeys()).toEqual([]);
  });

  it("takes a body of 65536 bytes and refuses 65537 with 413", async () => {
    const json = JSON.stringify(validCrash());
    expect((await crash(json.padEnd(65_536, " "))).status).toBe(204);
    await expectError(await crash(json.padEnd(65_537, " ")), 413, "too_large");
    expect(await storedKeys()).toHaveLength(1);
  });

  it("answers method_not_allowed to any method but POST", async () => {
    for (const method of ["GET", "PUT", "DELETE"]) {
      const response = await crash(validCrash(), freshIp(), method);
      expect(response.headers.get("Allow")).toBe("POST");
      await expectError(response, 405, "method_not_allowed");
    }
    expect(await storedKeys()).toEqual([]);
  });

  it("limits reports to 10 per minute per IP, apart from the ping limit", async () => {
    const ip = freshIp();
    for (let i = 0; i < 10; i++) expect((await crash(validCrash(), ip)).status).toBe(204);
    await expectError(await crash(validCrash(), ip), 429, "rate_limited");
    expect(await storedKeys()).toHaveLength(10);
    expect((await crash(validCrash())).status).toBe(204);
    // The spent report budget leaves this IP's pings alone.
    const install = "AAAAAAAAAAAAAAAAAAAAAA";
    const ping = await SELF.fetch(`${ORIGIN}/v1/ping`, {
      method: "POST",
      headers: { "CF-Connecting-IP": ip },
      body: JSON.stringify({ v: 1, install, app: "ios", version: "1.3.4", build: "245" }),
    });
    expect(ping.status).toBe(204);
  }, 20_000);
});

describe("crash report admin reads", () => {
  beforeEach(clearBucket);

  it("lists and returns stored reports to the admin token only", async () => {
    expect((await crash(validCrash())).status).toBe(204);
    expect((await crash(validHang())).status).toBe(204);

    await expectError(await admin("/v1/crash/reports", null), 401, "unauthorized");
    await expectError(await admin("/v1/crash/reports", `${ADMIN}x`), 401, "unauthorized");
    await expectError(await admin(`/v1/crash/reports/${(await storedKeys())[0]}`, "wrong"), 401, "unauthorized");

    const list = await admin("/v1/crash/reports");
    expect(list.status).toBe(200);
    expect(list.headers.get("Cache-Control")).toBe("no-store");
    const { keys, cursor } = (await list.json()) as { keys: { key: string; size: number; uploaded: string }[]; cursor: string | null };
    expect(cursor).toBeNull();
    expect(keys.map((entry) => entry.key).sort()).toEqual((await storedKeys()).sort());

    const crashKey = keys.find((entry) => entry.key.includes("/crash-"))!.key;
    const one = await admin(`/v1/crash/reports/${crashKey}`);
    expect(one.status).toBe(200);
    expect(await one.json()).toEqual(validCrash());

    const day = new Date().toISOString().slice(0, 10);
    const byDay = await admin(`/v1/crash/reports?prefix=v1/${day}/1.3.4-245/hang-`);
    expect(((await byDay.json()) as { keys: unknown[] }).keys).toHaveLength(1);
  });

  it("refuses malformed keys and prefixes, missing reports and other methods", async () => {
    await expectError(await admin("/v1/crash/reports/v1/2026-11-13/1.3.4-245/crash-AAAAAAAAAAAAAAAAAAAAAA.json"), 404, "not_found");
    await expectError(await admin("/v1/crash/reports/other/key.json"), 404, "not_found");
    await expectError(await admin("/v1/crash/reports?prefix=other/"), 400, "bad_request");
    await expectError(await admin("/v1/crash/reports", ADMIN, "POST"), 404, "not_found");
    await expectError(await admin("/v1/crash/elsewhere"), 404, "not_found");
  });
});

describe("crash report logging", () => {
  let lines: string[];

  beforeEach(() => {
    lines = [];
    for (const method of ["log", "info", "warn", "error", "debug"] as const) {
      vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
        lines.push(args.map(String).join(" "));
      });
    }
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("never logs a report, accepted or refused, nor an admin read", async () => {
    await crash(validCrash());
    await crash(validCrash({ agent: "claude" }));
    await crash(JSON.stringify(validCrash()).padEnd(70_000, " "));
    await crash(validCrash(), freshIp(), "GET");
    await admin("/v1/crash/reports", "wrong");
    await admin("/v1/crash/reports");
    expect(lines).toEqual([]);
  });
});
