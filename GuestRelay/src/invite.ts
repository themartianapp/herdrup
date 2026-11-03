// Short invite links (`/i/<id><key>`): the host daemon stores its v1 invite here as an
// AES-128-GCM blob under a random id, and the link carries the key. The relay keeps only
// the ciphertext, its owning host_id and its expiry; it never stores the key.
// Log lines carry only endpoint and outcome: never ids, host ids, blobs or secrets.
import { DurableObject } from "cloudflare:workers";
import { BEARER, errorResponse, log, readCapped, type Env } from "./relay";

/** Largest blob a host may store: nonce (12) || ciphertext || tag (16). */
export const MAX_BLOB_BYTES = 2048;
/** Nonce, tag and at least one byte of ciphertext. */
const MIN_BLOB_BYTES = 12 + 16 + 1;
/** Furthest expiry a blob may have. */
export const MAX_INVITE_SECONDS = 30 * 24 * 60 * 60;

const HOST_ID = /^[A-Za-z0-9_-]{22}$/;
const UNIX_SECONDS = /^[0-9]{1,12}$/;

export type InviteOutcome = "stored" | "exists" | "unauthorized" | "too_many_invites" | "deleted" | "forbidden";

const OUTCOME_STATUS: Record<InviteOutcome, number> = {
  stored: 201,
  exists: 409,
  unauthorized: 401,
  too_many_invites: 429,
  deleted: 204,
  forbidden: 403,
};

/** `PUT`, `GET` or `DELETE /v1/invite/<id>`, with `id` already checked to be 12 b64url characters. */
export async function handleInvite(request: Request, env: Env, id: string): Promise<Response> {
  const endpoint = "/v1/invite";
  try {
    if (request.method === "GET") {
      const blob = await env.INVITES.get(env.INVITES.idFromName(id)).read();
      if (blob === null) {
        log({ endpoint, outcome: "not_found" });
        return errorResponse(404, "not_found");
      }
      log({ endpoint, outcome: "fetched" });
      return new Response(blob, {
        headers: { "content-type": "application/octet-stream", "cache-control": "no-store" },
      });
    }

    // Both run in the Worker, before any Durable Object, as for the host socket: PUT and
    // DELETE share the per-IP host connect limit, so floods neither create objects nor
    // cost hashing.
    if (env.HOST_CONNECT_LIMIT === undefined) {
      log({ endpoint, outcome: "not_configured" });
      return errorResponse(500, "not_configured");
    }
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.HOST_CONNECT_LIMIT.limit({ key: ip })).success) {
      log({ endpoint, outcome: "rate_limited" });
      return errorResponse(429, "rate_limited");
    }
    const secret = BEARER.exec(request.headers.get("Authorization") ?? "")?.[1];
    if (secret === undefined) {
      log({ endpoint, outcome: "unauthorized" });
      return errorResponse(401, "unauthorized");
    }
    const hostId = request.headers.get("X-Herdr-Host") ?? "";
    if (!HOST_ID.test(hostId)) {
      log({ endpoint, outcome: "bad_request" });
      return errorResponse(400, "bad_request");
    }
    const host = env.HOSTS.get(env.HOSTS.idFromName(hostId));

    let outcome: InviteOutcome;
    if (request.method === "DELETE") {
      outcome = await host.deleteInvite(hostId, secret, id);
    } else {
      const expires = request.headers.get("X-Herdr-Expires") ?? "";
      const expiresUnix = UNIX_SECONDS.test(expires) ? Number(expires) : NaN;
      const now = Date.now() / 1000;
      if (!(expiresUnix > now && expiresUnix <= now + MAX_INVITE_SECONDS)) {
        log({ endpoint, outcome: "bad_expiry" });
        return errorResponse(400, "bad_expiry");
      }
      const blob = await readCapped(request, MAX_BLOB_BYTES);
      if (blob === null) {
        log({ endpoint, outcome: "too_large" });
        return errorResponse(413, "too_large");
      }
      if (blob.byteLength < MIN_BLOB_BYTES) {
        log({ endpoint, outcome: "bad_request" });
        return errorResponse(400, "bad_request");
      }
      outcome = await host.putInvite(hostId, secret, id, expiresUnix, blob);
    }
    log({ endpoint, outcome });
    const status = OUTCOME_STATUS[outcome];
    return status < 300 ? new Response(null, { status }) : errorResponse(status, outcome);
  } catch {
    // The error itself is deliberately not logged: it may echo request content.
    log({ endpoint, outcome: "internal_error" });
    return errorResponse(500, "internal_error");
  }
}

interface StoredInvite {
  blob: ArrayBuffer;
  host: string;
  expires: number;
}

/**
 * The Durable Object for one short-invite id: its blob, owning host_id and expiry, deleted
 * by an alarm at expiry. Reached only from the Worker's GET and from HostRelay, which has
 * already authenticated the host.
 */
export class InviteBlob extends DurableObject<Env> {
  /** Stores the blob unless a live one already holds this id. */
  async store(hostId: string, expiresUnix: number, blob: ArrayBuffer): Promise<boolean> {
    if ((await this.current()) !== null) return false;
    await this.ctx.storage.put<StoredInvite[keyof StoredInvite]>({ blob, host: hostId, expires: expiresUnix });
    await this.ctx.storage.setAlarm(expiresUnix * 1000);
    return true;
  }

  async read(): Promise<ArrayBuffer | null> {
    return (await this.current())?.blob ?? null;
  }

  /** Deletes the blob if `hostId` owns it. Nothing to delete counts as deleted. */
  async remove(hostId: string): Promise<"deleted" | "forbidden"> {
    const invite = await this.current();
    if (invite === null) return "deleted";
    if (invite.host !== hostId) return "forbidden";
    await this.clear();
    return "deleted";
  }

  async alarm(): Promise<void> {
    await this.clear();
  }

  /** The live invite. One past its expiry whose alarm hasn't run yet is deleted here. */
  private async current(): Promise<StoredInvite | null> {
    const entries = await this.ctx.storage.get<StoredInvite[keyof StoredInvite]>(["blob", "host", "expires"]);
    const blob = entries.get("blob");
    const host = entries.get("host");
    const expires = entries.get("expires");
    if (!(blob instanceof ArrayBuffer) || typeof host !== "string" || typeof expires !== "number") return null;
    if (expires <= Date.now() / 1000) {
      await this.clear();
      return null;
    }
    return { blob, host, expires };
  }

  private async clear(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }
}
