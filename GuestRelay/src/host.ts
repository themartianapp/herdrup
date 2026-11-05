// The Durable Object for one host_id: at most one host socket and its guest sessions.
// All routing state lives in WebSocket tags and attachments plus SQLite, so it survives
// hibernation; the object keeps nothing in memory between events.
import { DurableObject } from "cloudflare:workers";
import { CLOSE, DATA, OPEN, closeReason, encodeFrame, parseFrame } from "./frames";
import type { InviteOutcome } from "./invite";
import { BEARER, errorResponse, log, refuseGuest, type Env } from "./relay";

/** Largest WebSocket message either side may send; anything bigger closes with 1009. */
export const MAX_MESSAGE_BYTES = 70_000;
/** Open guest sessions per host. */
export const MAX_SESSIONS = 32;
/** Live short-invite blobs per host. */
export const MAX_INVITES = 200;
const MAX_SESSION_ID = 0xffff_ffff;

const CLOSE_NORMAL = 1000;
const CLOSE_GOING_AWAY = 1001;
const CLOSE_PROTOCOL_ERROR = 1002;
const CLOSE_UNSUPPORTED_DATA = 1003;
const CLOSE_ABNORMAL = 1006;
const CLOSE_TOO_BIG = 1009;
const CLOSE_REPLACED = 4000;

interface Attachment {
  role: "host" | "guest";
  /** The guest's session id; 0 for the host. */
  session: number;
  /**
   * The relay is done with this socket and ignores anything more from it. A host is
   * replaced or dropped and its guests are already closed; a guest is being closed and
   * the host already has (or needs no) CLOSE for it.
   */
  ended?: true;
}

export class HostRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Only the SHA-256 of the host's relay secret is stored, never the secret itself.
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS host (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        secret_sha256 BLOB NOT NULL,
        next_session INTEGER NOT NULL
      )`,
    );
    // The host's live short-invite ids, for the per-host cap. The blobs live in InviteBlob.
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS invite (
        id TEXT PRIMARY KEY,
        expires_unix INTEGER NOT NULL
      )`,
    );
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    return pathname.startsWith("/v1/host/") ? this.connectHost(request) : this.connectGuest();
  }

  private async connectHost(request: Request): Promise<Response> {
    const endpoint = "/v1/host";
    const secret = BEARER.exec(request.headers.get("Authorization") ?? "")?.[1];
    if (secret === undefined) {
      log({ endpoint, outcome: "unauthorized" });
      return errorResponse(401, "unauthorized");
    }
    const trust = await this.authenticate(secret, "enroll");
    if (trust === "refused") {
      log({ endpoint, outcome: "unauthorized" });
      return errorResponse(401, "unauthorized");
    }

    const previous = this.currentHost();
    if (previous !== undefined) {
      log({ endpoint, outcome: "replaced", code: CLOSE_REPLACED });
      this.retireHost(previous, CLOSE_REPLACED, "replaced");
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["host"]);
    server.serializeAttachment({ role: "host", session: 0 } satisfies Attachment);
    log({ endpoint, outcome: trust });
    return new Response(null, { status: 101, webSocket: client });
  }

  /**
   * Checks a relay secret against the stored SHA-256, for the host socket and the invite
   * endpoints alike. Only the host socket (`"enroll"`) trusts the secret of a host_id with
   * no hash yet (trust on first use); the invite endpoints (`"verify"`) refuse it, so they
   * never enroll a host_id. The daemon always connects its host socket before it stores
   * an invite.
   */
  private async authenticate(secret: string, mode: "enroll" | "verify"): Promise<"enrolled" | "connected" | "refused"> {
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
    // Synchronous from here on, so no other connect can interleave between the read and
    // the trust-on-first-use insert.
    const sql = this.ctx.storage.sql;
    const stored = sql.exec<{ secret_sha256: ArrayBuffer }>("SELECT secret_sha256 FROM host WHERE id = 1").toArray()[0];
    if (stored === undefined) {
      if (mode === "verify") return "refused";
      sql.exec("INSERT INTO host (id, secret_sha256, next_session) VALUES (1, ?, 1)", hash);
      return "enrolled";
    }
    return crypto.subtle.timingSafeEqual(stored.secret_sha256, hash) ? "connected" : "refused";
  }

  /** Stores a short-invite blob for this host, within its cap of live invites. */
  async putInvite(hostId: string, secret: string, id: string, expiresUnix: number, blob: ArrayBuffer): Promise<InviteOutcome> {
    if ((await this.authenticate(secret, "verify")) === "refused") return "unauthorized";
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM invite WHERE expires_unix <= ?", Math.floor(Date.now() / 1000));
    if (sql.exec("SELECT 1 FROM invite WHERE id = ?", id).toArray().length > 0) return "exists";
    if (sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM invite").one().n >= MAX_INVITES) return "too_many_invites";
    // Reserve the slot before yielding, so concurrent PUTs can't pass the cap together.
    sql.exec("INSERT INTO invite (id, expires_unix) VALUES (?, ?)", id, expiresUnix);
    let stored = false;
    try {
      stored = await this.env.INVITES.get(this.env.INVITES.idFromName(id)).store(hostId, expiresUnix, blob);
    } finally {
      if (!stored) sql.exec("DELETE FROM invite WHERE id = ?", id);
    }
    return stored ? "stored" : "exists";
  }

  /** Deletes a short-invite blob this host stored. One that is already gone counts as deleted. */
  async deleteInvite(hostId: string, secret: string, id: string): Promise<InviteOutcome> {
    if ((await this.authenticate(secret, "verify")) === "refused") return "unauthorized";
    const outcome = await this.env.INVITES.get(this.env.INVITES.idFromName(id)).remove(hostId);
    if (outcome === "deleted") this.ctx.storage.sql.exec("DELETE FROM invite WHERE id = ?", id);
    return outcome;
  }

  private connectGuest(): Response {
    const endpoint = "/v1/guest";
    const host = this.currentHost();
    if (host === undefined) return refuseGuest("host_offline");
    if (this.ctx.getWebSockets("guest").filter((ws) => !attachment(ws).ended).length >= MAX_SESSIONS) {
      return refuseGuest("host_busy");
    }

    // Persisted, so ids keep increasing across host reconnects and evictions. After the u32
    // wrap, skip 0 and any id a socket still holds; few sockets are ever held, so this ends.
    const sql = this.ctx.storage.sql;
    let session = sql.exec<{ next_session: number }>("SELECT next_session FROM host WHERE id = 1").one().next_session;
    while (session === 0 || this.ctx.getWebSockets(`session:${session}`).length > 0) {
      session = session >= MAX_SESSION_ID ? 1 : session + 1;
    }
    sql.exec("UPDATE host SET next_session = ? WHERE id = 1", session >= MAX_SESSION_ID ? 1 : session + 1);

    // OPEN goes first: if the host socket fails now, no orphan guest socket is left behind.
    // Nothing yields before the accept, so the host can't answer the session before it exists.
    host.send(encodeFrame(OPEN, session));
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["guest", `session:${session}`]);
    server.serializeAttachment({ role: "guest", session } satisfies Attachment);
    log({ endpoint, outcome: "opened" });
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    const att = attachment(ws);
    if (att.ended) return;
    const size = typeof message === "string" ? new TextEncoder().encode(message).byteLength : message.byteLength;

    if (att.role === "host") {
      if (size > MAX_MESSAGE_BYTES) return this.dropHost(ws, CLOSE_TOO_BIG, "message_too_big");
      if (typeof message === "string") return this.dropHost(ws, CLOSE_UNSUPPORTED_DATA, "binary_only");
      const frame = parseFrame(message);
      if (frame === null || frame.type === OPEN) return this.dropHost(ws, CLOSE_PROTOCOL_ERROR, "bad_frame");
      // No open session: the relay already closed it and sent the host a CLOSE.
      const guest = this.ctx.getWebSockets(`session:${frame.session}`).find((g) => !attachment(g).ended);
      if (guest === undefined) return;
      if (frame.type === DATA) {
        guest.send(frame.payload);
      } else {
        closeGuest(guest, CLOSE_NORMAL, closeReason(frame.payload));
      }
      return;
    }

    if (size > MAX_MESSAGE_BYTES) return this.endSession(ws, att.session, CLOSE_TOO_BIG, "message_too_big");
    if (typeof message === "string") return this.endSession(ws, att.session, CLOSE_UNSUPPORTED_DATA, "binary_only");
    const host = this.currentHost();
    if (host === undefined) return closeGuest(ws, CLOSE_GOING_AWAY, "host_offline");
    host.send(encodeFrame(DATA, att.session, message));
  }

  webSocketClose(ws: WebSocket, code: number): void {
    this.socketGone(ws, code);
    // Complete the closing handshake. 1005, 1006 and 1015 are reserved and never sent.
    closeSocket(ws, code === 1005 || code === CLOSE_ABNORMAL || code === 1015 ? CLOSE_NORMAL : code);
  }

  webSocketError(ws: WebSocket): void {
    // The error is not logged: it may carry peer-supplied detail.
    this.socketGone(ws, CLOSE_ABNORMAL);
  }

  /** The peer closed or the connection failed: tell the other side. */
  private socketGone(ws: WebSocket, code: number): void {
    const att = attachment(ws);
    if (att.role === "host") {
      if (!att.ended) this.retireHost(ws);
    } else if (!att.ended) {
      markEnded(ws);
      this.currentHost()?.send(encodeFrame(CLOSE, att.session));
    }
    log({ endpoint: att.role === "host" ? "/v1/host" : "/v1/guest", outcome: "closed", code });
  }

  private currentHost(): WebSocket | undefined {
    return this.ctx
      .getWebSockets("host")
      .find((ws) => ws.readyState === WebSocket.READY_STATE_OPEN && !attachment(ws).ended);
  }

  /** Stops routing to a host socket, closes it if a code is given, and closes all its guests. */
  private retireHost(host: WebSocket, code?: number, reason?: string): void {
    markEnded(host);
    if (code !== undefined) closeSocket(host, code, reason);
    for (const guest of this.ctx.getWebSockets("guest")) {
      if (!attachment(guest).ended) closeGuest(guest, CLOSE_GOING_AWAY, "host_offline");
    }
  }

  private dropHost(host: WebSocket, code: number, reason: string): void {
    log({ endpoint: "/v1/host", outcome: reason, code });
    this.retireHost(host, code, reason);
  }

  /** The relay ends a guest session itself: the host gets CLOSE, the guest gets `code`. */
  private endSession(guest: WebSocket, session: number, code: number, reason: string): void {
    log({ endpoint: "/v1/guest", outcome: reason, code });
    this.currentHost()?.send(encodeFrame(CLOSE, session));
    closeGuest(guest, code, reason);
  }
}

function attachment(ws: WebSocket): Attachment {
  return ws.deserializeAttachment() as Attachment;
}

function markEnded(ws: WebSocket): void {
  ws.serializeAttachment({ ...attachment(ws), ended: true } satisfies Attachment);
}

function closeGuest(guest: WebSocket, code: number, reason: string): void {
  markEnded(guest);
  closeSocket(guest, code, reason);
}

function closeSocket(ws: WebSocket, code: number, reason?: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // The peer already closed it.
  }
}
