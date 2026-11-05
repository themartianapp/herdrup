import {
  SELF,
  env,
  evictDurableObject,
  listDurableObjectIds,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import { browserLink, invitePayload, isRelay, openShortInvite, shortInvite } from "../public/static/invite.js";

// Everything here runs against the real Worker and Durable Object in workerd. Each test
// uses its own host_id and client IPs, so storage and rate-limit state never collide.

const ORIGIN = "https://guest.herdrup.themartian.app";
const OPEN = 0x01;
const DATA = 0x02;
const CLOSE = 0x03;
const MAX_MESSAGE = 70_000;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const newHostId = () => b64url(crypto.getRandomValues(new Uint8Array(16)));
const newSecret = () => b64url(crypto.getRandomValues(new Uint8Array(32)));
const newInvitePayload = () =>
  b64url(
    utf8(
      JSON.stringify({
        v: 1,
        relay: ORIGIN,
        host_id: newHostId(),
        host_pub: newSecret(),
        invite_id: newHostId(),
        secret: newSecret(),
        machine_label: "llm-opt",
        owner_name: "Jerry",
        agent_name: "claude",
        guest_name: "Luca",
        expires_unix: 1_900_000_000,
      }),
    ),
  );

let ipCounter = 0;
const freshIp = () => `2001:db8::${(++ipCounter).toString(16)}`;

const utf8 = (text: string) => new TextEncoder().encode(text);
const text = (bytes: Uint8Array) => new TextDecoder().decode(bytes);

function frame(type: number, session: number, payload: Uint8Array = new Uint8Array(0)): ArrayBuffer {
  const bytes = new Uint8Array(5 + payload.byteLength);
  bytes[0] = type;
  new DataView(bytes.buffer).setUint32(1, session);
  bytes.set(payload, 5);
  return bytes.buffer;
}

interface Frame {
  type: number;
  session: number;
  payload: Uint8Array;
}

function parse(message: ArrayBuffer | string): Frame {
  if (typeof message === "string") throw new Error(`expected a binary frame, got text ${message}`);
  const view = new DataView(message);
  return { type: view.getUint8(0), session: view.getUint32(1), payload: new Uint8Array(message, 5) };
}

interface Closed {
  code: number;
  reason: string;
}

/** One end of a WebSocket, with its messages queued in order. A missing message or close fails on the test timeout. */
class Peer {
  private readonly queue: (ArrayBuffer | string)[] = [];
  private readonly waiters: ((message: ArrayBuffer | string) => void)[] = [];
  private readonly closeEvent = Promise.withResolvers<Closed>();
  /** The close code and reason this end received. */
  readonly closed = this.closeEvent.promise;

  constructor(readonly ws: WebSocket) {
    ws.binaryType = "arraybuffer";
    ws.accept();
    ws.addEventListener("message", (event) => {
      const waiter = this.waiters.shift();
      if (waiter) waiter(event.data as ArrayBuffer | string);
      else this.queue.push(event.data as ArrayBuffer | string);
    });
    ws.addEventListener("close", (event) => {
      this.closeEvent.resolve({ code: event.code, reason: event.reason });
    });
  }

  next(): Promise<ArrayBuffer | string> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    const { promise, resolve } = Promise.withResolvers<ArrayBuffer | string>();
    this.waiters.push(resolve);
    return promise;
  }

  async nextFrame(): Promise<Frame> {
    return parse(await this.next());
  }

  send(message: ArrayBuffer | Uint8Array | string): void {
    this.ws.send(message);
  }
}

interface GuestSession {
  guest: Peer;
  session: number;
}

function hostRequest(hostId: string, authorization?: string, upgrade = true, ip = freshIp()): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": ip };
  if (upgrade) headers.Upgrade = "websocket";
  if (authorization !== undefined) headers.Authorization = authorization;
  return SELF.fetch(`${ORIGIN}/v1/host/${hostId}`, { headers });
}

function guestRequest(hostId: string, ip = freshIp(), upgrade = true): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": ip };
  if (upgrade) headers.Upgrade = "websocket";
  return SELF.fetch(`${ORIGIN}/v1/guest/${hostId}`, { headers });
}

async function connectHost(hostId: string, secret: string): Promise<Peer> {
  const response = await hostRequest(hostId, `Bearer ${secret}`);
  expect(response.status).toBe(101);
  return new Peer(response.webSocket!);
}

/** Connects a guest and returns it with the session id the host was told in OPEN. */
async function connectGuest(host: Peer, hostId: string, ip?: string): Promise<GuestSession> {
  const response = await guestRequest(hostId, ip);
  expect(response.status).toBe(101);
  const guest = new Peer(response.webSocket!);
  const open = await host.nextFrame();
  expect(open.type).toBe(OPEN);
  expect(open.payload.byteLength).toBe(0);
  return { guest, session: open.session };
}

/** An error before the upgrade: status, JSON body and the X-Herdr-Guest-Error header agree. */
async function expectError(response: Response, status: number, code: string): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.webSocket).toBeNull();
  expect(response.headers.get("X-Herdr-Guest-Error")).toBe(code);
  expect(await response.json()).toEqual({ error: code });
}

/** A refused guest upgrade: accepted, then closed at once with the refusal's code and reason. */
async function expectRefusal(response: Response, code: number, reason: string): Promise<void> {
  expect(response.status).toBe(101);
  expect(await new Peer(response.webSocket!).closed).toEqual({ code, reason });
}

const stub = (hostId: string) => env.HOSTS.get(env.HOSTS.idFromName(hostId));

const newInviteId = () => b64url(crypto.getRandomValues(new Uint8Array(9)));
const nowUnix = () => Math.floor(Date.now() / 1000);

/** Enrolls a host with the relay, as its daemon does by connecting, and hangs up. */
async function enrolledHost(): Promise<{ hostId: string; secret: string }> {
  const hostId = newHostId();
  const secret = newSecret();
  const host = await connectHost(hostId, secret);
  host.ws.close(1000);
  await host.closed;
  return { hostId, secret };
}

/** A short-invite blob: nonce (12) || AES-128-GCM ciphertext || tag (16), with the id as AAD. */
async function seal(id: string, key: Uint8Array, plaintext: Uint8Array): Promise<ArrayBuffer> {
  const aes = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: utf8(id) }, aes, plaintext));
  const blob = new Uint8Array(12 + sealed.byteLength);
  blob.set(nonce);
  blob.set(sealed, 12);
  return blob.buffer;
}

interface InviteOptions {
  hostId?: string;
  authorization?: string;
  expires?: string;
  body?: Uint8Array;
  /** CF-Connecting-IP; a fresh one by default, so the per-IP host limit never trips. */
  ip?: string;
}

function inviteRequest(method: string, id: string, options: InviteOptions = {}): Promise<Response> {
  const headers: Record<string, string> = { "CF-Connecting-IP": options.ip ?? freshIp() };
  if (options.authorization !== undefined) headers.Authorization = options.authorization;
  if (options.hostId !== undefined) headers["X-Herdr-Host"] = options.hostId;
  if (options.expires !== undefined) headers["X-Herdr-Expires"] = options.expires;
  if (options.body !== undefined) headers["Content-Type"] = "application/octet-stream";
  return SELF.fetch(`${ORIGIN}/v1/invite/${id}`, { method, headers, body: options.body });
}

function putInvite(host: { hostId: string; secret: string }, id: string, options: InviteOptions = {}): Promise<Response> {
  return inviteRequest("PUT", id, {
    hostId: host.hostId,
    authorization: `Bearer ${host.secret}`,
    expires: String(nowUnix() + 3600),
    body: crypto.getRandomValues(new Uint8Array(600)),
    ...options,
  });
}

function deleteInvite(host: { hostId: string; secret: string }, id: string, options: InviteOptions = {}): Promise<Response> {
  return inviteRequest("DELETE", id, { hostId: host.hostId, authorization: `Bearer ${host.secret}`, ...options });
}

const inviteStub = (id: string) => env.INVITES.get(env.INVITES.idFromName(id));

const newInstall = () => b64url(crypto.getRandomValues(new Uint8Array(16)));
const validPing = (fields: Record<string, unknown> = {}) => ({ v: 1, install: newInstall(), app: "ios", version: "1.4.0", build: "212", ...fields });

/** `POST /v1/ping` from a fresh IP by default, so the per-IP ping limit never trips. */
function ping(body: unknown, ip = freshIp(), method = "POST"): Promise<Response> {
  const raw = typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body);
  return SELF.fetch(`${ORIGIN}/v1/ping`, {
    method,
    headers: { "CF-Connecting-IP": ip, "Content-Type": "application/json" },
    body: method === "GET" ? undefined : raw,
  });
}

describe("routing", () => {
  it("answers health", async () => {
    const response = await SELF.fetch(`${ORIGIN}/v1/health`);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, version: expect.any(String) });
  });

  // Asset requests never reach the Worker (so /i is never logged); SELF skips the asset
  // router in tests, so the page is fetched through the ASSETS binding instead.
  it("serves the invite landing page and every asset it references, locked down by CSP", async () => {
    const response = await env.ASSETS.fetch(`${ORIGIN}/i`);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toMatch(/^text\/html/);
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    // The page fetches a short invite's blob from its own origin, and nowhere else.
    expect(response.headers.get("content-security-policy")).toContain("connect-src 'self';");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await response.text();
    expect(html).toContain('href="https://apps.apple.com/app/id6798087089"');
    expect(html).toContain('<a class="btn quiet" id="browser" hidden>Open in browser</a>');

    const css = await (await env.ASSETS.fetch(`${ORIGIN}/static/i.css`)).text();
    const refs = [...html.matchAll(/(?:src|href)="(\/[^"]+)"/g), ...css.matchAll(/url\((\/[^)]+)\)/g)].map((m) => m[1]);
    expect(refs).toEqual(expect.arrayContaining(["/static/i.js", "/static/i.css", "/fonts/Geist-Regular.woff2"]));
    const js = await (await env.ASSETS.fetch(`${ORIGIN}/static/i.js`)).text();
    const imports = [...js.matchAll(/from "\.\/([^"]+)"/g)].map((m) => `/static/${m[1]}`);
    expect(imports).toEqual(["/static/invite.js"]);
    for (const ref of [...refs, ...imports]) {
      expect([ref, (await env.ASSETS.fetch(`${ORIGIN}${ref}`)).status]).toEqual([ref, 200]);
    }
  });

  it("serves the landing page for /i/<payload> with the /i headers", async () => {
    const page = await (await env.ASSETS.fetch(`${ORIGIN}/i`)).text();
    const shortLink = newInviteId() + b64url(crypto.getRandomValues(new Uint8Array(16)));
    for (const payload of [newInvitePayload(), shortLink, "A", "-_".repeat(2048)]) {
      const response = await SELF.fetch(`${ORIGIN}/i/${payload}`);
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toMatch(/^text\/html/);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("referrer-policy")).toBe("no-referrer");
      expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
      expect(await response.text()).toBe(page);
    }
  });

  // Owner-approved policy for the browser guest (web guest contract, "Hosting").
  const WEB_CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; " +
    "font-src 'self'; connect-src 'self' wss://guest.herdrup.app wss://guest.herdrup.themartian.app; " +
    "frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'";

  function expectWebHeaders(response: Response, cacheControl: string) {
    expect(response.headers.get("content-security-policy")).toBe(WEB_CSP);
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("cache-control")).toBe(cacheControl);
  }

  it("serves the browser guest's index.html at /web/ and every path under it, never cached", async () => {
    const index = await env.ASSETS.fetch(`${ORIGIN}/web/`);
    expect(index.status).toBe(200);
    expect(index.headers.get("content-type")).toMatch(/^text\/html/);
    expectWebHeaders(index, "no-store");
    const page = await index.text();
    expect(page).toContain('<script type="module" crossorigin src="/web/assets/');
    for (const path of ["/web", "/web/index.html"]) {
      const response = await env.ASSETS.fetch(`${ORIGIN}${path}`, { redirect: "manual" });
      expect([path, response.status, response.headers.get("location")]).toEqual([path, 307, "/web/"]);
    }

    for (const path of ["/web/x", "/web/chat/agent", "/web/a/b/", "/web/x.html", "/web/%2F..%2Fi"]) {
      const response = await SELF.fetch(`${ORIGIN}${path}`);
      expect([path, response.status]).toEqual([path, 200]);
      expect(response.headers.get("content-type")).toMatch(/^text\/html/);
      expectWebHeaders(response, "no-store");
      expect(await response.text()).toBe(page);
    }
    await expectError(await SELF.fetch(`${ORIGIN}/web/x`, { method: "POST" }), 404, "not_found");
  });

  it("serves the browser guest's hashed assets with a long immutable cache, and every file as built", async () => {
    const page = await (await env.ASSETS.fetch(`${ORIGIN}/web/`)).text();
    const hashed = [...page.matchAll(/(?:src|href)="(\/web\/assets\/[^"]+)"/g)].map((m) => m[1]);
    expect(hashed).toHaveLength(2);
    for (const ref of hashed) {
      const response = await env.ASSETS.fetch(`${ORIGIN}${ref}`);
      expect([ref, response.status]).toEqual([ref, 200]);
      expect(response.headers.get("content-type")).toMatch(/^(text\/javascript|application\/javascript|text\/css)/);
      expectWebHeaders(response, "public, max-age=31536000, immutable");
    }

    // The manifest's hashes are checked against public/web by node --test; this checks that
    // ASSETS serves those same bytes at the same paths.
    const manifest = await (await env.ASSETS.fetch(`${ORIGIN}/web/manifest.json`)).json<{ files: Record<string, string> }>();
    for (const [path, sha256] of Object.entries(manifest.files)) {
      const url = path === "index.html" ? `${ORIGIN}/web/` : `${ORIGIN}/web/${path}`;
      const response = await env.ASSETS.fetch(url);
      expect([path, response.status]).toEqual([path, 200]);
      expect(response.headers.get("content-security-policy")).toBe(WEB_CSP);
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await response.arrayBuffer()));
      expect([path, Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("")]).toEqual([path, sha256]);
    }
  });

  it("answers not_found for an /i/ path that is not a b64url payload", async () => {
    const payload = newInvitePayload();
    for (const path of [
      "/i/",
      `/i/${payload}/`,
      `/i/${payload}/x`,
      `/i/${payload}.html`,
      `/i/${payload}+`,
      `/i/${payload}=`,
      `/i/${payload}%2F`,
      `/i/<${payload}>`,
      `/i/${"A".repeat(4097)}`,
      `/x/${payload}`,
    ]) {
      await expectError(await SELF.fetch(`${ORIGIN}${path}`), 404, "not_found");
    }
    await expectError(await SELF.fetch(`${ORIGIN}/i/${payload}`, { method: "POST" }), 404, "not_found");
  });

  it("rejects unknown paths, malformed host ids and other methods with not_found", async () => {
    const hostId = newHostId();
    await expectError(await SELF.fetch(`${ORIGIN}/v1/nope`), 404, "not_found");
    await expectError(await hostRequest(hostId.slice(1), `Bearer ${newSecret()}`), 404, "not_found");
    await expectError(await guestRequest(`${hostId}A`), 404, "not_found");
    await expectError(await guestRequest(`${hostId.slice(2)}+/`), 404, "not_found");
    // workerd's fetch() sends every Upgrade: websocket request as GET, so the method check is probed without it.
    await expectError(await SELF.fetch(`${ORIGIN}/v1/guest/${hostId}`, { method: "POST" }), 404, "not_found");
  });

  it("requires a WebSocket upgrade on both socket endpoints", async () => {
    const hostId = newHostId();
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`, false), 426, "upgrade_required");
    await expectError(await guestRequest(hostId, freshIp(), false), 426, "upgrade_required");
  });
});

describe("host authentication", () => {
  it("trusts the first secret, refuses any other, and stores only its hash", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const host = await connectHost(hostId, secret);

    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
    // The refused connect left the trusted host in place.
    const { session } = await connectGuest(host, hostId);
    expect(session).toBe(1);

    const rows = await runInDurableObject(stub(hostId), (_, state) =>
      state.storage.sql.exec("SELECT * FROM host").toArray(),
    );
    const expected = new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(secret)));
    expect(rows).toHaveLength(1);
    expect(new Uint8Array(rows[0].secret_sha256 as ArrayBuffer)).toEqual(expected);
    const stored = JSON.stringify(rows, (_, v) => (v instanceof ArrayBuffer ? Array.from(new Uint8Array(v)) : v));
    expect(stored).not.toContain(secret);
  });

  it("refuses missing or malformed credentials without trusting them", async () => {
    const hostId = newHostId();
    await expectError(await hostRequest(hostId), 401, "unauthorized");
    await expectError(await hostRequest(hostId, "Bearer short"), 401, "unauthorized");
    await expectError(await hostRequest(hostId, `Basic ${newSecret()}`), 401, "unauthorized");
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}x`), 401, "unauthorized");

    // Nothing was trusted by those attempts: the first well-formed secret still wins.
    const secret = newSecret();
    await connectHost(hostId, secret);
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
  });

  it("keeps separate trust per host id", async () => {
    const [a, b] = [newHostId(), newHostId()];
    const secret = newSecret();
    await connectHost(a, secret);
    await connectHost(b, newSecret());
    await expectError(await hostRequest(b, `Bearer ${secret}`), 401, "unauthorized");
  });

  it("replaces the host socket with a newer authenticated one", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const old = await connectHost(hostId, secret);
    const { guest, session } = await connectGuest(old, hostId);

    const current = await connectHost(hostId, secret);
    expect(await old.closed).toEqual({ code: 4000, reason: "replaced" });
    // Sessions belonged to the old socket; the new host never heard of them.
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });

    const next = await connectGuest(current, hostId);
    expect(next.session).toBeGreaterThan(session);
    current.send(frame(DATA, next.session, utf8("hello")));
    expect(text(new Uint8Array((await next.guest.next()) as ArrayBuffer))).toBe("hello");
  });
});

describe("guest sessions", () => {
  it("closes with 4503 host_offline when no host is connected", async () => {
    const hostId = newHostId();
    await expectRefusal(await guestRequest(hostId), 4503, "host_offline");

    const host = await connectHost(hostId, newSecret());
    await connectGuest(host, hostId);
    host.ws.close(1000, "bye");
    await host.closed;
    await expectRefusal(await guestRequest(hostId), 4503, "host_offline");
    // A request that isn't an upgrade still gets the HTTP error.
    await expectError(await guestRequest(hostId, freshIp(), false), 426, "upgrade_required");
  });

  it("routes two concurrent guests to their own sessions", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);
    expect(b.session).toBeGreaterThan(a.session);

    host.send(frame(DATA, b.session, utf8("to-b")));
    host.send(frame(DATA, a.session, utf8("to-a")));
    expect(text(new Uint8Array((await a.guest.next()) as ArrayBuffer))).toBe("to-a");
    expect(text(new Uint8Array((await b.guest.next()) as ArrayBuffer))).toBe("to-b");

    b.guest.send(utf8("from-b"));
    a.guest.send(utf8("from-a"));
    const first = await host.nextFrame();
    const second = await host.nextFrame();
    expect([first.type, first.session, text(first.payload)]).toEqual([DATA, b.session, "from-b"]);
    expect([second.type, second.session, text(second.payload)]).toEqual([DATA, a.session, "from-a"]);
  });

  it("answers a text ping with pong on both sockets", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest } = await connectGuest(host, hostId);
    host.send("ping");
    expect(await host.next()).toBe("pong");
    guest.send("ping");
    expect(await guest.next()).toBe("pong");
  });

  it("wraps session ids after the largest u32", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    await runInDurableObject(stub(hostId), (_, state) => {
      state.storage.sql.exec("UPDATE host SET next_session = 4294967295");
    });
    expect((await connectGuest(host, hostId)).session).toBe(0xffff_ffff);
    expect((await connectGuest(host, hostId)).session).toBe(1);
  });

  it("skips ids still held by open sessions when the counter wraps", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const one = await connectGuest(host, hostId);
    const two = await connectGuest(host, hostId);
    expect([one.session, two.session]).toEqual([1, 2]);
    await runInDurableObject(stub(hostId), (_, state) => {
      state.storage.sql.exec("UPDATE host SET next_session = 4294967295");
    });
    expect((await connectGuest(host, hostId)).session).toBe(0xffff_ffff);
    const wrapped = await connectGuest(host, hostId);
    expect(wrapped.session).toBe(3);

    // The old sessions still get only their own traffic.
    host.send(frame(DATA, 1, utf8("to-one")));
    host.send(frame(DATA, 3, utf8("to-three")));
    expect(text(new Uint8Array((await one.guest.next()) as ArrayBuffer))).toBe("to-one");
    expect(text(new Uint8Array((await wrapped.guest.next()) as ArrayBuffer))).toBe("to-three");
  });

  it("keeps routing and numbering sessions after the object hibernates", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const host = await connectHost(hostId, secret);
    const a = await connectGuest(host, hostId);

    await evictDurableObject(stub(hostId));

    host.send(frame(DATA, a.session, utf8("after")));
    expect(text(new Uint8Array((await a.guest.next()) as ArrayBuffer))).toBe("after");
    a.guest.send(utf8("back"));
    const data = await host.nextFrame();
    expect([data.type, data.session, text(data.payload)]).toEqual([DATA, a.session, "back"]);
    expect((await connectGuest(host, hostId)).session).toBe(a.session + 1);
    await expectError(await hostRequest(hostId, `Bearer ${newSecret()}`), 401, "unauthorized");
  });
});

describe("close propagation", () => {
  it("sends the host CLOSE when a guest closes", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    guest.ws.close(1000, "done");
    const close = await host.nextFrame();
    expect([close.type, close.session, close.payload.byteLength]).toEqual([CLOSE, session, 0]);
    expect((await guest.closed).code).toBe(1000);
  });

  it("closes the guest with the host's reason when the host sends CLOSE", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);

    host.send(frame(CLOSE, a.session, utf8("invite_used")));
    expect(await a.guest.closed).toEqual({ code: 1000, reason: "invite_used" });
    // DATA for the closed session is dropped; the other session is untouched.
    host.send(frame(DATA, a.session, utf8("late")));
    host.send(frame(DATA, b.session, utf8("still here")));
    expect(text(new Uint8Array((await b.guest.next()) as ArrayBuffer))).toBe("still here");
    // The relay echoes no CLOSE for a session the host closed: the next frame is the new OPEN.
    const c = await connectGuest(host, hostId);
    expect(c.session).toBeGreaterThan(b.session);
  });

  it("closes the guest without a reason when the host's reason is too long", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    host.send(frame(CLOSE, session, utf8("x".repeat(124))));
    expect(await guest.closed).toEqual({ code: 1000, reason: "" });
  });

  it("closes every guest with 1001 when the host goes away", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const a = await connectGuest(host, hostId);
    const b = await connectGuest(host, hostId);
    host.ws.close(1000, "restart");
    expect(await a.guest.closed).toEqual({ code: 1001, reason: "host_offline" });
    expect(await b.guest.closed).toEqual({ code: 1001, reason: "host_offline" });
  });
});

describe("limits", () => {
  it("forwards a 70000-byte guest message and closes a bigger one with 1009", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);

    guest.send(new Uint8Array(MAX_MESSAGE).fill(7));
    const data = await host.nextFrame();
    expect([data.type, data.session, data.payload.byteLength]).toEqual([DATA, session, MAX_MESSAGE]);

    guest.send(new Uint8Array(MAX_MESSAGE + 1));
    expect((await guest.closed).code).toBe(1009);
    const close = await host.nextFrame();
    expect([close.type, close.session]).toEqual([CLOSE, session]);
  });

  it("forwards a 70000-byte host message and closes a bigger one with 1009", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);

    host.send(frame(DATA, session, new Uint8Array(MAX_MESSAGE - 5).fill(9)));
    expect(((await guest.next()) as ArrayBuffer).byteLength).toBe(MAX_MESSAGE - 5);

    host.send(frame(DATA, session, new Uint8Array(MAX_MESSAGE - 4)));
    expect((await host.closed).code).toBe(1009);
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });
    await expectRefusal(await guestRequest(hostId), 4503, "host_offline");
  });

  it("caps a host at 32 open sessions", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const guests: GuestSession[] = [];
    for (let i = 0; i < 32; i++) guests.push(await connectGuest(host, hostId));

    await expectRefusal(await guestRequest(hostId), 4504, "host_busy");

    guests[0].guest.ws.close(1000, "done");
    // The refused guest opened no session: the host's next frame is this CLOSE, not an OPEN.
    expect((await host.nextFrame()).type).toBe(CLOSE);
    const admitted = await connectGuest(host, hostId);
    expect(admitted.session).toBe(guests[31].session + 1);
  });

  it("limits guest connects to 30 per minute per IP", async () => {
    const hostId = newHostId();
    const ip = freshIp();
    // With no host, each connect that passes the limiter is closed host_offline. Each counts
    // once: accepting and closing a refused socket is not another connect.
    for (let i = 0; i < 30; i++) await expectRefusal(await guestRequest(hostId, ip), 4503, "host_offline");
    await expectRefusal(await guestRequest(hostId, ip), 4429, "rate_limited");
    await expectRefusal(await guestRequest(hostId, freshIp()), 4503, "host_offline");
  });

  it("closes a rate-limited guest before any Durable Object is reached", async () => {
    const ip = freshIp();
    const spent = newHostId();
    for (let i = 0; i < 30; i++) await expectRefusal(await guestRequest(spent, ip), 4503, "host_offline");

    const unseen = newHostId();
    await expectRefusal(await guestRequest(unseen, ip), 4429, "rate_limited");
    const created = (await listDurableObjectIds(env.HOSTS)).map((id) => id.toString());
    expect(created).not.toContain(env.HOSTS.idFromName(unseen).toString());

    // A connected host never hears of a rate-limited guest: the next admitted guest's OPEN
    // is the host's first frame, with the first session id.
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    await expectRefusal(await guestRequest(hostId, ip), 4429, "rate_limited");
    expect((await connectGuest(host, hostId)).session).toBe(1);

    // A request that isn't an upgrade still gets the HTTP error, before the limiter.
    await expectError(await guestRequest(hostId, ip, false), 426, "upgrade_required");
  });

  it("limits host connects to 10 per minute per IP before the Durable Object is reached", async () => {
    const ip = freshIp();
    const hostIds: string[] = [];
    for (let i = 0; i < 10; i++) {
      const hostId = newHostId();
      hostIds.push(hostId);
      // Malformed bearers count toward the limit but are refused in the Worker.
      await expectError(await hostRequest(hostId, "Bearer short", true, ip), 401, "unauthorized");
    }
    await expectError(await hostRequest(newHostId(), `Bearer ${newSecret()}`, true, ip), 429, "rate_limited");
    expect((await hostRequest(newHostId(), `Bearer ${newSecret()}`, true, freshIp())).status).toBe(101);

    // None of the refused connects created a Durable Object.
    const created = new Set((await listDurableObjectIds(env.HOSTS)).map((id) => id.toString()));
    for (const hostId of hostIds) expect(created.has(env.HOSTS.idFromName(hostId).toString())).toBe(false);
  });

  it("closes a guest that sends text with 1003 and tells the host", async () => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest, session } = await connectGuest(host, hostId);
    guest.send("hello");
    expect((await guest.closed).code).toBe(1003);
    const close = await host.nextFrame();
    expect([close.type, close.session]).toEqual([CLOSE, session]);
  });

  it.each([
    ["text", "hello", 1003],
    ["a frame shorter than its header", new Uint8Array([DATA, 0, 0, 1]).buffer, 1002],
    ["an OPEN frame", frame(OPEN, 1), 1002],
    ["an unknown frame type", frame(0x7f, 1), 1002],
  ])("drops a host that sends %s", async (_, message, code) => {
    const hostId = newHostId();
    const host = await connectHost(hostId, newSecret());
    const { guest } = await connectGuest(host, hostId);
    host.send(message);
    expect((await host.closed).code).toBe(code);
    expect(await guest.closed).toEqual({ code: 1001, reason: "host_offline" });
  });
});

describe("short invites", () => {
  it("stores a blob, serves it to anyone uncached, and deletes it for its host", async () => {
    const host = await enrolledHost();
    const id = newInviteId();
    const blob = crypto.getRandomValues(new Uint8Array(700));
    const put = await putInvite(host, id, { body: blob });
    expect(put.status).toBe(201);

    const get = await SELF.fetch(`${ORIGIN}/v1/invite/${id}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("application/octet-stream");
    expect(get.headers.get("cache-control")).toBe("no-store");
    expect(new Uint8Array(await get.arrayBuffer())).toEqual(blob);

    expect((await deleteInvite(host, id)).status).toBe(204);
    await expectError(await SELF.fetch(`${ORIGIN}/v1/invite/${id}`), 404, "not_found");
    // Already gone still counts as deleted.
    expect((await deleteInvite(host, id)).status).toBe(204);
  });

  it("authenticates PUT and DELETE against the host's stored secret", async () => {
    const host = await enrolledHost();
    const id = newInviteId();
    await expectError(await putInvite(host, id, { authorization: undefined }), 401, "unauthorized");
    await expectError(await putInvite(host, id, { authorization: "Bearer short" }), 401, "unauthorized");
    await expectError(await putInvite(host, id, { authorization: `Bearer ${newSecret()}` }), 401, "unauthorized");
    expect((await putInvite(host, id)).status).toBe(201);
    await expectError(await deleteInvite({ ...host, secret: newSecret() }, id), 401, "unauthorized");
    expect((await SELF.fetch(`${ORIGIN}/v1/invite/${id}`)).status).toBe(200);
  });

  it("never enrolls a host_id: only a host connect does", async () => {
    const storedSecrets = (hostId: string) =>
      runInDurableObject(stub(hostId), (_, state) => state.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM host").one().n);
    const unknown = { hostId: newHostId(), secret: newSecret() };
    await expectError(await putInvite(unknown, newInviteId()), 401, "unauthorized");
    await expectError(await deleteInvite(unknown, newInviteId()), 401, "unauthorized");
    expect(await storedSecrets(unknown.hostId)).toBe(0);
    // A later host connect, with any secret, still enrolls as usual; then invites work.
    const secret = newSecret();
    expect((await hostRequest(unknown.hostId, `Bearer ${secret}`)).status).toBe(101);
    expect(await storedSecrets(unknown.hostId)).toBe(1);
    await expectError(await putInvite(unknown, newInviteId()), 401, "unauthorized");
    expect((await putInvite({ hostId: unknown.hostId, secret }, newInviteId())).status).toBe(201);
  });

  it("counts PUT and DELETE toward the per-IP host limit before any Durable Object is reached", async () => {
    const host = await enrolledHost();
    const ip = freshIp();
    const hostIds: string[] = [];
    for (let i = 0; i < 10; i++) {
      const hostId = newHostId();
      hostIds.push(hostId);
      // Host connects and invite requests share the budget; malformed bearers are refused in the Worker.
      const response = i % 2 === 0
        ? await putInvite({ hostId, secret: "" }, newInviteId(), { authorization: "Bearer short", ip })
        : await hostRequest(hostId, "Bearer short", true, ip);
      await expectError(response, 401, "unauthorized");
    }
    const id = newInviteId();
    await expectError(await putInvite(host, id, { ip }), 429, "rate_limited");
    await expectError(await deleteInvite(host, id, { ip }), 429, "rate_limited");
    const stranger = newHostId();
    await expectError(await putInvite({ hostId: stranger, secret: newSecret() }, newInviteId(), { ip }), 429, "rate_limited");
    expect((await putInvite(host, id)).status).toBe(201);

    const hosts = new Set((await listDurableObjectIds(env.HOSTS)).map((d) => d.toString()));
    for (const hostId of [...hostIds, stranger]) expect(hosts.has(env.HOSTS.idFromName(hostId).toString())).toBe(false);
  });

  it("lets only the owning host delete a blob", async () => {
    const owner = await enrolledHost();
    const other = await enrolledHost();
    const id = newInviteId();
    expect((await putInvite(owner, id)).status).toBe(201);
    await expectError(await deleteInvite(other, id), 403, "forbidden");
    expect((await SELF.fetch(`${ORIGIN}/v1/invite/${id}`)).status).toBe(200);
  });

  it("refuses a duplicate id, from the same host or another", async () => {
    const host = await enrolledHost();
    const id = newInviteId();
    const blob = crypto.getRandomValues(new Uint8Array(100));
    expect((await putInvite(host, id, { body: blob })).status).toBe(201);
    await expectError(await putInvite(host, id), 409, "exists");
    await expectError(await putInvite(await enrolledHost(), id), 409, "exists");
    expect(new Uint8Array(await (await SELF.fetch(`${ORIGIN}/v1/invite/${id}`)).arrayBuffer())).toEqual(blob);
  });

  it("caps a blob at 2048 bytes and refuses one too short to hold nonce and tag", async () => {
    const host = await enrolledHost();
    await expectError(await putInvite(host, newInviteId(), { body: new Uint8Array(2049) }), 413, "too_large");
    await expectError(await putInvite(host, newInviteId(), { body: new Uint8Array(28) }), 400, "bad_request");
    await expectError(await putInvite(host, newInviteId(), { body: new Uint8Array(0) }), 400, "bad_request");
    expect((await putInvite(host, newInviteId(), { body: new Uint8Array(2048) })).status).toBe(201);
  });

  it("needs an expiry in the future and at most 30 days away", async () => {
    const host = await enrolledHost();
    const now = nowUnix();
    for (const expires of [String(now - 1), String(now), String(now + 30 * 86400 + 60), "", "soon", "1.5", "-5", `${now + 60}x`]) {
      await expectError(await putInvite(host, newInviteId(), { expires }), 400, "bad_expiry");
    }
    expect((await putInvite(host, newInviteId(), { expires: String(now + 30 * 86400 - 60) })).status).toBe(201);
  });

  it("needs a well-formed X-Herdr-Host", async () => {
    const host = await enrolledHost();
    await expectError(await putInvite(host, newInviteId(), { hostId: host.hostId.slice(1) }), 400, "bad_request");
    await expectError(await deleteInvite({ ...host, hostId: `${host.hostId}+` }, newInviteId()), 400, "bad_request");
  });

  it("answers not_found for a malformed id or another method", async () => {
    const id = newInviteId();
    for (const path of [`/v1/invite/${id.slice(1)}`, `/v1/invite/${id}A`, `/v1/invite/${id.slice(1)}+`, `/v1/invite/${id}/`]) {
      await expectError(await SELF.fetch(`${ORIGIN}${path}`), 404, "not_found");
    }
    await expectError(await SELF.fetch(`${ORIGIN}/v1/invite/${id}`, { method: "POST" }), 404, "not_found");
  });

  it("treats a blob past its expiry as gone, and its alarm deletes it at expiry", async () => {
    const host = await enrolledHost();
    const lapsed = newInviteId();
    expect((await putInvite(host, lapsed)).status).toBe(201);
    // As if the expiry passed before the alarm ran.
    await runInDurableObject(inviteStub(lapsed), async (_, state) => {
      await state.storage.put("expires", nowUnix() - 1);
    });
    await expectError(await SELF.fetch(`${ORIGIN}/v1/invite/${lapsed}`), 404, "not_found");
    expect(await runInDurableObject(inviteStub(lapsed), (_, state) => state.storage.list())).toEqual(new Map());

    const id = newInviteId();
    const expires = nowUnix() + 600;
    expect((await putInvite(host, id, { expires: String(expires) })).status).toBe(201);
    expect(await runInDurableObject(inviteStub(id), (_, state) => state.storage.getAlarm())).toBe(expires * 1000);
    expect(await runDurableObjectAlarm(inviteStub(id))).toBe(true);
    expect(await runInDurableObject(inviteStub(id), (_, state) => state.storage.list())).toEqual(new Map());
    await expectError(await SELF.fetch(`${ORIGIN}/v1/invite/${id}`), 404, "not_found");
  });

  it("holds at most 200 live invites per host", async () => {
    const host = await enrolledHost();
    const ids = Array.from({ length: 4 }, newInviteId);
    expect((await putInvite(host, ids[0])).status).toBe(201);
    // 197 more live invites, plus one expired that no longer counts.
    await runInDurableObject(stub(host.hostId), (_, state) => {
      for (let i = 0; i < 197; i++) state.storage.sql.exec("INSERT INTO invite (id, expires_unix) VALUES (?, ?)", `filler${i}`, nowUnix() + 3600);
      state.storage.sql.exec("INSERT INTO invite (id, expires_unix) VALUES (?, ?)", "lapsed", nowUnix() - 1);
    });
    // Concurrent, so the cap also holds while PUTs interleave.
    const statuses = await Promise.all(ids.slice(1).map(async (id) => (await putInvite(host, id)).status));
    expect(statuses.sort()).toEqual([201, 201, 429]);
    await expectError(await putInvite(host, newInviteId()), 429, "too_many_invites");
    // Other hosts are unaffected, and deleting one frees a slot.
    expect((await putInvite(await enrolledHost(), newInviteId())).status).toBe(201);
    expect((await deleteInvite(host, ids[0])).status).toBe(204);
    expect((await putInvite(host, newInviteId())).status).toBe(201);
  });
});

describe("usage ping", () => {
  let writes: MockInstance<AnalyticsEngineDataset["writeDataPoint"]>;

  beforeEach(() => {
    writes = vi.spyOn(env.USAGE, "writeDataPoint");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("writes one data point of install, app, version and build for an accepted ping", async () => {
    const body = validPing({ app: "ipados", version: "2.10.1-beta_3", build: "4021" });
    const response = await ping(body);
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(writes.mock.calls).toEqual([[{ indexes: [body.install], blobs: ["ipados", "2.10.1-beta_3", "4021"], doubles: [1] }]]);
  });

  it("accepts every client in the contract and a 32-character version and build", async () => {
    const apps = ["ios", "ipados", "macos-catalyst", "desktop-macos", "desktop-linux", "desktop-windows"];
    for (const app of apps) expect((await ping(validPing({ app, version: "v".repeat(32), build: "9".repeat(32) }))).status).toBe(204);
    expect(writes.mock.calls.map(([point]) => point?.blobs?.[0])).toEqual(apps);
  });

  it("refuses anything but the exact schema with 400 and writes nothing", async () => {
    const { v: _v, ...noV } = validPing();
    const { app: _app, ...noApp } = validPing();
    const bodies: unknown[] = [
      validPing({ v: 2 }),
      validPing({ v: "1" }),
      noV,
      validPing({ install: newInstall().slice(1) }),
      validPing({ install: `${newInstall()}A` }),
      validPing({ install: `${newInstall().slice(2)}==` }),
      validPing({ install: `${newInstall().slice(1)}+` }),
      validPing({ install: 42 }),
      validPing({ app: "android" }),
      validPing({ app: "iOS" }),
      noApp,
      validPing({ version: "" }),
      validPing({ version: "1".repeat(33) }),
      validPing({ version: "1.0 beta" }),
      validPing({ version: 1.4 }),
      validPing({ build: "" }),
      validPing({ build: "2".repeat(33) }),
      validPing({ build: "21/2" }),
      validPing({ locale: "en_GB" }),
      [validPing()],
      "null",
      "",
      "not json",
      `${JSON.stringify(validPing())}x`,
      new Uint8Array([0x7b, 0xff, 0x7d]),
    ];
    for (const body of bodies) await expectError(await ping(body), 400, "bad_request");
    expect(writes).not.toHaveBeenCalled();
  });

  it("takes a body of 512 bytes and refuses 513 with 400", async () => {
    const json = JSON.stringify(validPing());
    expect((await ping(json.padEnd(512, " "))).status).toBe(204);
    await expectError(await ping(json.padEnd(513, " ")), 400, "bad_request");
    expect(writes).toHaveBeenCalledTimes(1);
  });

  it("answers method_not_allowed to any method but POST", async () => {
    for (const method of ["GET", "PUT", "DELETE"]) {
      const response = await ping(validPing(), freshIp(), method);
      expect(response.headers.get("Allow")).toBe("POST");
      await expectError(response, 405, "method_not_allowed");
    }
    expect(writes).not.toHaveBeenCalled();
  });

  // About 110 requests, which can pass the default 5 s timeout while the whole suite runs.
  it("limits pings to 60 per minute per IP, apart from the host and guest connect limits", async () => {
    const ip = freshIp();
    const statuses = await Promise.all(Array.from({ length: 60 }, async () => (await ping(validPing(), ip)).status));
    expect(statuses).toEqual(Array(60).fill(204));
    await expectError(await ping(validPing(), ip), 429, "rate_limited");
    expect(writes).toHaveBeenCalledTimes(60);
    expect((await ping(validPing())).status).toBe(204);
    // The spent ping budget leaves this IP's connects alone: each still passes its limiter.
    const hostId = newHostId();
    await expectRefusal(await guestRequest(hostId, ip), 4503, "host_offline");
    await expectError(await hostRequest(hostId, "Bearer short", true, ip), 401, "unauthorized");

    // And spent connect budgets leave this IP's pings alone. Spend them one at a time, as
    // the connect-limit tests do: fired concurrently, the limiter could still let the 31st
    // guest connect through ("expected 503 to be 429" on CI runs 41775711449, 41777510910).
    const busy = freshIp();
    for (let i = 0; i < 30; i++) await guestRequest(hostId, busy);
    for (let i = 0; i < 10; i++) await hostRequest(hostId, "Bearer short", true, busy);
    await expectRefusal(await guestRequest(hostId, busy), 4429, "rate_limited");
    await expectError(await hostRequest(hostId, "Bearer short", true, busy), 429, "rate_limited");
    expect((await ping(validPing(), busy)).status).toBe(204);
  }, 20_000);
});

describe("landing page script", () => {
  it("takes the payload from the /i/<payload> path, else from the older /i#<payload> fragment", () => {
    expect(invitePayload("/i/eyJ2IjoxfQ", "")).toBe("eyJ2IjoxfQ");
    expect(invitePayload("/i/eyJ2IjoxfQ", "#other")).toBe("eyJ2IjoxfQ");
    expect(invitePayload("/i", "#eyJ2IjoxfQ")).toBe("eyJ2IjoxfQ");
    expect(invitePayload("/i", "")).toBe("");
    expect(invitePayload("/i/", "#eyJ2IjoxfQ")).toBe("eyJ2IjoxfQ");
  });

  it("reads a short link as one 34-character segment, id then key, and anything else as long", () => {
    const id = newInviteId();
    const key = b64url(crypto.getRandomValues(new Uint8Array(16)));
    expect(shortInvite(`/i/${id}${key}`)).toEqual({ id, key });
    expect(shortInvite(`/i/${id}${key}A`)).toBeNull();
    expect(shortInvite(`/i/${id}${key.slice(1)}`)).toBeNull();
    expect(shortInvite(`/i/${id}${key.slice(1)}+`)).toBeNull();
    expect(shortInvite(`/i/${id}/${key}`)).toBeNull();
    expect(shortInvite(`/i/${newInvitePayload()}`)).toBeNull();
    expect(shortInvite("/i")).toBeNull();
  });

  it("decrypts a short invite into the payload a long link carries, bound to its id, key and relay", async () => {
    const id = newInviteId();
    const keyBytes = crypto.getRandomValues(new Uint8Array(16));
    const key = b64url(keyBytes);
    const payload = newInvitePayload();
    const plaintext = Uint8Array.from(atob(payload.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((payload.length + 3) % 4)), (c) => c.charCodeAt(0));
    const blob = await seal(id, keyBytes, plaintext);

    expect(await openShortInvite({ id, key }, blob, ORIGIN)).toBe(payload);
    await expect(openShortInvite({ id: newInviteId(), key }, blob, ORIGIN)).rejects.toThrow();
    await expect(openShortInvite({ id, key: b64url(crypto.getRandomValues(new Uint8Array(16))) }, blob, ORIGIN)).rejects.toThrow();
    await expect(openShortInvite({ id, key }, blob, "https://evil.example")).rejects.toThrow();
    const tampered = new Uint8Array(blob.slice(0));
    tampered[20] ^= 1;
    await expect(openShortInvite({ id, key }, tampered.buffer, ORIGIN)).rejects.toThrow();
    await expect(openShortInvite({ id, key }, new ArrayBuffer(28), ORIGIN)).rejects.toThrow();
  });

  it("accepts the invite's relay with a trailing slash, as the app does, and nothing else", async () => {
    expect(isRelay(ORIGIN, ORIGIN)).toBe(true);
    expect(isRelay(`${ORIGIN}/`, ORIGIN)).toBe(true);
    for (const other of ["http://guest.herdrup.themartian.app", "https://guest.herdrup.themartian.app:8443",
      "https://GUEST.herdrup.themartian.app", "https://guest.herdrup.themartian.app:443",
      "https://evil.example", `${ORIGIN}/relay`, `${ORIGIN}//`, `${ORIGIN}/?x=1`, `${ORIGIN}#x`,
      `${ORIGIN}\\@evil.example/..`, `${ORIGIN}/..`, `${ORIGIN}/./`,
      "https://user@guest.herdrup.themartian.app", "not a url", "", 7, null]) {
      expect(isRelay(other, ORIGIN), String(other)).toBe(false);
    }

    // Review of #608: the browser's URL parser reads this as the relay, the app's as evil.example.
    const bypassId = newInviteId();
    const bypassKey = crypto.getRandomValues(new Uint8Array(16));
    const bypass = await seal(bypassId, bypassKey,
      utf8(JSON.stringify({ v: 1, relay: `${ORIGIN}\\@evil.example/..` })));
    await expect(openShortInvite({ id: bypassId, key: b64url(bypassKey) }, bypass, ORIGIN))
      .rejects.toThrow("relay mismatch");

    const id = newInviteId();
    const keyBytes = crypto.getRandomValues(new Uint8Array(16));
    const plaintext = utf8(JSON.stringify({ v: 1, relay: `${ORIGIN}/` }));
    const blob = await seal(id, keyBytes, plaintext);
    const opened = await openShortInvite({ id, key: b64url(keyBytes) }, blob, ORIGIN);
    expect(JSON.parse(atob(opened.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((opened.length + 3) % 4))).relay)
      .toBe(`${ORIGIN}/`);
  });

  it("links Open in browser to /web/ with the app link's payload in the fragment, for long and short links", async () => {
    const payload = newInvitePayload();
    const expectLink = (link: string) => {
      expect(link).toBe(`/web/#${payload}`);
      const url = new URL(link, ORIGIN);
      expect([url.origin, url.pathname, url.search, url.hash]).toEqual([ORIGIN, "/web/", "", `#${payload}`]);
    };
    expectLink(browserLink(invitePayload(`/i/${payload}`, "")));
    expectLink(browserLink(invitePayload("/i", `#${payload}`)));

    const id = newInviteId();
    const keyBytes = crypto.getRandomValues(new Uint8Array(16));
    const plaintext = Uint8Array.from(atob(payload.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((payload.length + 3) % 4)), (c) => c.charCodeAt(0));
    const short = shortInvite(`/i/${id}${b64url(keyBytes)}`);
    expect(short).not.toBeNull();
    expectLink(browserLink(await openShortInvite(short!, await seal(id, keyBytes, plaintext), ORIGIN)));
  });
});

describe("logging", () => {
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

  it("logs only endpoint, outcome and close code", async () => {
    const hostId = newHostId();
    const secret = newSecret();
    const marker = "PLAINTEXT-MARKER-4d2c";
    const host = await connectHost(hostId, secret);
    await hostRequest(hostId, `Bearer ${newSecret()}`);
    const { guest, session } = await connectGuest(host, hostId);
    guest.send(utf8(`guest says ${marker}`));
    await host.nextFrame();
    host.send(frame(DATA, session, utf8(`host says ${marker}`)));
    await guest.next();
    guest.send(new Uint8Array(MAX_MESSAGE + 1).fill(0x41));
    await guest.closed;
    expect((await host.nextFrame()).type).toBe(CLOSE);
    const second = await connectGuest(host, hostId);
    host.send(frame(CLOSE, second.session, utf8(`reason ${marker}`)));
    await second.guest.closed;
    host.ws.close(1000, `bye ${marker}`);
    await host.closed;
    await guestRequest(hostId);

    const outcomes = lines.map((line) => {
      const parsed = JSON.parse(line) as Record<string, unknown>;
      expect(Object.keys(parsed).every((key) => ["endpoint", "outcome", "code"].includes(key))).toBe(true);
      return `${parsed.endpoint} ${parsed.outcome}`;
    });
    expect(outcomes).toEqual(
      expect.arrayContaining([
        "/v1/host enrolled",
        "/v1/host unauthorized",
        "/v1/guest opened",
        "/v1/guest message_too_big",
        "/v1/guest closed",
        "/v1/host closed",
        "/v1/guest host_offline",
      ]),
    );
    const all = lines.join("\n");
    for (const secretText of [hostId, secret, marker]) expect(all).not.toContain(secretText);
  });

  it("never logs an invite link's payload", async () => {
    const payload = newInvitePayload();
    await SELF.fetch(`${ORIGIN}/i/${payload}`);
    await SELF.fetch(`${ORIGIN}/i/${payload}+`);
    await SELF.fetch(`${ORIGIN}/i/${payload}`, { method: "POST" });
    await SELF.fetch(`${ORIGIN}/v1/guest/${payload}`, { headers: { Upgrade: "websocket" } });
    const all = lines.join("\n");
    expect(all).not.toContain(payload.slice(0, 40));
  });

  it("logs nothing for the browser guest", async () => {
    const payload = newInvitePayload();
    await SELF.fetch(`${ORIGIN}/web/${payload}`);
    await SELF.fetch(`${ORIGIN}/web/${payload}`, { method: "POST" });
    await SELF.fetch(`${ORIGIN}/web/x?${payload}`);
    expect(lines).toEqual([]);
  });

  it("never logs a short invite's id, key, host or secret", async () => {
    const host = await enrolledHost();
    const other = await enrolledHost();
    const id = newInviteId();
    const key = b64url(crypto.getRandomValues(new Uint8Array(16)));
    await putInvite(host, id);
    await putInvite(host, id);
    await putInvite(host, id, { authorization: `Bearer ${newSecret()}` });
    await putInvite(host, newInviteId(), { expires: "0" });
    await putInvite(host, newInviteId(), { body: new Uint8Array(4096) });
    await SELF.fetch(`${ORIGIN}/i/${id}${key}`);
    await SELF.fetch(`${ORIGIN}/v1/invite/${id}`);
    await deleteInvite(other, id);
    await deleteInvite(host, id);
    await SELF.fetch(`${ORIGIN}/v1/invite/${id}`);

    const outcomes = lines.map((line) => {
      const parsed = JSON.parse(line) as Record<string, unknown>;
      expect(Object.keys(parsed).every((k) => ["endpoint", "outcome", "code"].includes(k))).toBe(true);
      return `${parsed.endpoint} ${parsed.outcome}`;
    });
    expect(outcomes.filter((o) => o.startsWith("/v1/invite "))).toEqual([
      "/v1/invite stored",
      "/v1/invite exists",
      "/v1/invite unauthorized",
      "/v1/invite bad_expiry",
      "/v1/invite too_large",
      "/v1/invite fetched",
      "/v1/invite forbidden",
      "/v1/invite deleted",
      "/v1/invite not_found",
    ]);
    const all = lines.join("\n");
    for (const secretText of [id, key, host.hostId, host.secret, other.hostId, other.secret]) expect(all).not.toContain(secretText);
  });

  it("never logs a ping, accepted or refused", async () => {
    const install = newInstall();
    await ping(validPing({ install }));
    await ping(validPing({ install, app: "android" }));
    await ping(JSON.stringify(validPing({ install })).padEnd(600, " "));
    await ping(validPing({ install }), freshIp(), "GET");
    expect(lines).toEqual([]);
  });
});
