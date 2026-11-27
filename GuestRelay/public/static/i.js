// Renders a guest invite from the URL: the path of /i/<payload>, or the fragment of older
// /i#<payload> links. The payload is b64url(JSON) as defined in the guest access contract.
// A short link /i/<id><key> instead names an encrypted blob on this relay: the page fetches
// /v1/invite/<id> (never the key), decrypts it here, and renders the payload inside.
// Every field is written with textContent, and only a b64url payload is ever placed in the
// app link and the browser links (/web/#<payload>, and /web/#<payload>&bind=1&provider=… for an
// account invite), which all carry it in the fragment, so no request ever sends it to a server.
import { accountInvite, accountLink, addAccountLink, browserLink, checkSignedIn, installTarget, invitePayload, openShortInvite, shortInvite, tintIndex } from "./invite.js";

(async function () {
  var APP_LINK = "herdrup://guest-invite#";
  var B64URL = /^[A-Za-z0-9_-]+$/;
  var $ = function (id) { return document.getElementById(id); };

  // The App Store app is for iPhone and iPad only; a computer gets HerdrUp Desktop instead.
  var target = installTarget(navigator.userAgent, navigator.maxTouchPoints);
  var device = target === "ios" ? "phone" : target === "desktop" ? "computer" : "device";
  var install = target === "ios" ? $("store") : target === "desktop" ? $("desktop") : null;
  if (target === "desktop") {
    $("lead").textContent = "Open this link on the computer or iPhone where HerdrUp is installed.";
    $("hint").textContent = "No HerdrUp yet? Click Open in browser, or install HerdrUp for desktop, then come back to this page and click Open in HerdrUp.";
  } else if (target !== "ios") {
    $("lead").textContent = "Open this link on the iPhone or computer where HerdrUp is installed.";
    $("hint").textContent = "No HerdrUp for this device? Tap Open in browser.";
  }

  // Where to get HerdrUp, chosen once the page knows what it shows (an invite, or a problem):
  // under an account invite's choice, one line naming the install capsule's own link and words;
  // anywhere else, the capsule and the hint.
  function offerInstall(account) {
    if (!account) {
      if (install !== null) install.hidden = false;
      return;
    }
    $("hint").hidden = true;
    if (install === null) return;
    var getLink = $("get-link");
    getLink.href = install.href;
    getLink.textContent = install.textContent;
    $("get").hidden = false;
  }

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
    offerInstall(false);
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
  var browser = $("browser");
  browser.href = browserLink(payload);

  var invite;
  try {
    invite = decode(payload);
  } catch (e) {
    invite = null;
  }
  if (!validInvite(invite)) {
    open.hidden = false;
    browser.hidden = false;
    problem("This invite link looks incomplete. Try opening it in HerdrUp, or ask for the link again.");
    return;
  }

  document.title = invite.owner_name + " shared " + invite.agent_name + " with you · HerdrUp";
  $("avatar").textContent = Array.from(invite.agent_name)[0].toUpperCase();
  // The agent's own gradient, as its avatar tile in the agent lists.
  $("avatar").classList.add("tint-" + tintIndex(invite.agent_name));
  $("title").textContent = invite.owner_name + " shared " + invite.agent_name + " with you";
  $("lead").textContent = "You'll be able to watch it work and send it messages and files from this " + device + ".";
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

  // An account invite (acct: 1) checks if this browser is already signed in to HerdrUp. When
  // signed in, the primary button adds the agent directly to the signed-in account without
  // asking to sign in again; otherwise it offers Open in HerdrUp plus Apple/Google sign-in.
  var account = accountInvite(invite, location.origin);
  if (account) {
    var session = await checkSignedIn(fetch, navigator.locks, 2500);
    if (session.signedIn) {
      $("signed-in-lead").textContent = session.displayHint
        ? "Signed in as " + session.displayHint
        : "Signed in to your HerdrUp account in this browser.";
      $("add-account").href = addAccountLink(payload);
      $("signed-in").hidden = false;
      open.classList.remove("primary");
      open.classList.add("quiet");
      open.textContent = "Open in HerdrUp app";
      open.hidden = false;
      $("signed-in-device").href = browserLink(payload);
      $("signed-in-device").hidden = false;
    } else {
      open.hidden = false;
      $("apple").href = accountLink(payload, "apple");
      $("google").href = accountLink(payload, "google");
      $("device").href = browserLink(payload);
      $("choice").hidden = false;
    }
  } else {
    open.hidden = false;
    browser.hidden = false;
  }
  offerInstall(account);
})();
