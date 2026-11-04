// Renders a guest invite from the URL: the path of /i/<payload>, or the fragment of older
// /i#<payload> links. The payload is b64url(JSON) as defined in the guest access contract.
// A short link /i/<id><key> instead names an encrypted blob on this relay: the page fetches
// /v1/invite/<id> (never the key), decrypts it here, and renders the payload inside.
// Every field is written with textContent, and only a b64url payload is ever placed in the
// app link and the browser link (/web/#<payload>), which both carry it in the fragment, so
// no request ever sends it to a server.
import { browserLink, invitePayload, openShortInvite, shortInvite } from "./invite.js";

(async function () {
  var APP_LINK = "herdrup://guest-invite#";
  var B64URL = /^[A-Za-z0-9_-]+$/;
  var $ = function (id) { return document.getElementById(id); };

  function decode(payload) {
    var base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    var binary = atob(base64 + "===".slice((base64.length + 3) % 4));
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  }

  function isText(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 200;
  }

  function validInvite(invite) {
    return invite !== null && typeof invite === "object" && invite.v === 1 &&
      isText(invite.machine_label) && isText(invite.owner_name) && isText(invite.agent_name) &&
      isText(invite.guest_name) && typeof invite.expires_unix === "number";
  }

  function problem(text) {
    var el = $("problem");
    el.textContent = text;
    el.hidden = false;
  }

  function expiryText(expiresUnix) {
    var seconds = expiresUnix - Date.now() / 1000;
    if (seconds <= 0) return null;
    var hours = Math.floor(seconds / 3600);
    if (hours >= 1) return "Works once · expires in " + hours + " h";
    return "Works once · expires in " + Math.max(1, Math.floor(seconds / 60)) + " min";
  }

  // Following an older /i#… invite link while this page is open changes only the hash.
  window.addEventListener("hashchange", function () { location.reload(); });

  var short = shortInvite(location.pathname);
  var payload;
  if (short !== null) {
    var blob = null;
    var status = 0;
    try {
      var response = await fetch("/v1/invite/" + short.id, { cache: "no-store", credentials: "omit" });
      status = response.status;
      if (response.ok) blob = await response.arrayBuffer();
    } catch (e) {
      blob = null;
    }
    if (status === 404) {
      problem("This invite has expired or was revoked.");
      return;
    }
    if (blob === null) {
      problem("Couldn't load this invite. Check your connection, then reload this page.");
      return;
    }
    try {
      payload = await openShortInvite(short, blob, location.origin);
    } catch (e) {
      problem("This invite link is damaged. Ask for the link again, or paste the whole link into HerdrUp.");
      return;
    }
  } else {
    payload = invitePayload(location.pathname, location.hash);
    if (payload === "") {
      problem("This page opens HerdrUp invites. The link you followed has no invite in it. Ask for the link again.");
      return;
    }
    if (!B64URL.test(payload)) {
      problem("This invite link is damaged. Ask for the link again, or paste the whole link into HerdrUp.");
      return;
    }
  }

  var open = $("open");
  open.href = APP_LINK + payload;
  open.hidden = false;
  var browser = $("browser");
  browser.href = browserLink(payload);
  browser.hidden = false;

  var invite;
  try {
    invite = decode(payload);
  } catch (e) {
    invite = null;
  }
  if (!validInvite(invite)) {
    problem("This invite link looks incomplete. Try opening it in HerdrUp, or ask for the link again.");
    return;
  }

  document.title = invite.owner_name + " shared " + invite.agent_name + " with you · HerdrUp";
  $("avatar").textContent = Array.from(invite.agent_name)[0].toUpperCase();
  $("title").textContent = invite.owner_name + " shared " + invite.agent_name + " with you";
  $("lead").textContent = "You'll be able to watch it work and send it messages and files from this phone.";
  $("machine").textContent = invite.machine_label;
  $("agent").textContent = invite.agent_name;
  $("guest").textContent = invite.guest_name;
  $("note-agent").textContent = invite.agent_name;
  $("note-prefix").textContent = invite.guest_name + " (via HerdrUp):";
  $("note-owner").textContent = invite.owner_name;

  var expiry = $("expiry");
  var remaining = expiryText(invite.expires_unix);
  if (remaining === null) {
    expiry.textContent = "This invite has expired. Ask " + invite.owner_name + " for a new one.";
    expiry.classList.add("expired");
  } else {
    expiry.textContent = remaining;
  }
  $("details").hidden = false;
})();
