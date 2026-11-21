#!/usr/bin/env python3
"""Ensure and install the distribution profiles used by the TestFlight lane.

Usage: ensure_extension_profile.py TARGET [TARGET ...], with targets from TARGETS.
The owner approved the app/share App Group and keychain signing changes for #500.
Existing distribution certificates are reused. Profiles lacking required App Group
entitlements are regenerated; missing portal associations fail before the archive.
No credential or CI-secret changes are needed.
"""
import base64
import json
import os
import sys
import plistlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT (installed in the extension-signing venv)

# Profile filenames are local to the signing runner. Only app/share need App Groups.
TARGETS = {
    "app": {
        "bundle_id": "com.jerryfane.herdr",
        "bundle_name": "Herdrup",
        "profile_name": "Herdrup App Store",
        "file": "herdr.mobileprovision",
        "label": "app",
        "app_group": "group.com.jerryfane.herdr",
        # HerdrUp account sign-in (#698): the App ID has the Sign in with Apple capability, and
        # App/Herdr.entitlements asks for it, so a profile without it can't sign the archive.
        "entitlement_keys": ["com.apple.developer.applesignin"],
    },
    "share": {
        "bundle_id": "com.jerryfane.herdr.share",
        "bundle_name": "Herdrup Share Extension",
        "profile_name": "Herdrup Share Extension App Store",
        "file": "herdr-share.mobileprovision",
        "label": "share extension",
        "app_group": "group.com.jerryfane.herdr",
    },
    "widgets": {
        "bundle_id": "com.jerryfane.herdr.widgets",
        "bundle_name": "Herdrup Widgets",
        "profile_name": "Herdrup Widgets App Store",
        "file": "herdr-widgets.mobileprovision",
        "label": "widget",
    },
    "notificationservice": {
        "bundle_id": "com.jerryfane.herdr.notificationservice",
        "bundle_name": "Herdrup Notification Service",
        "profile_name": "Herdrup Notification Service App Store",
        "file": "herdr-notificationservice.mobileprovision",
        "label": "notification service",
    },
}
PROFILE_TYPE = "IOS_APP_STORE"
DIST_TYPES = ("DISTRIBUTION", "IOS_DISTRIBUTION")
BASE = "https://api.appstoreconnect.apple.com/v1"
INSTALL_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")

TOKEN = None


def make_token():
    with open(os.environ["ASC_KEYFILE"]) as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
         "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def api(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")}


def die(msg, payload=None):
    print("::error::" + msg)
    if payload is not None:
        print(json.dumps(payload, indent=2)[:2000])
    sys.exit(1)


def ensure_bundle_id(t):
    bundle_id, bundle_name = t["bundle_id"], t["bundle_name"]
    q = urllib.parse.quote(bundle_id)
    st, r = api("GET", f"/bundleIds?filter[identifier]={q}&limit=1")
    if st != 200:
        die(f"ASC bundleIds query failed (HTTP {st}) — the key may lack "
            "Certificates/Identifiers access.", r)
    if r.get("data"):
        rid = r["data"][0]["id"]
        print(f"bundle id exists: {bundle_id} ({rid})")
        return rid
    st, r = api("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": bundle_id, "name": bundle_name, "platform": "IOS"}}})
    if st not in (200, 201):
        die(f"could not CREATE bundle id {bundle_id} (HTTP {st}) — the ASC key likely "
            f"lacks permission. STOP and have the owner mint the {t['label']} profile.", r)
    rid = r["data"]["id"]
    print(f"created bundle id: {bundle_id} ({rid})")
    return rid


def ensure_app_groups(t, bundle_rid):
    if "app_group" not in t:
        return
    st, result = api("GET", f"/bundleIds/{bundle_rid}/bundleIdCapabilities")
    if st != 200:
        die(f"cannot read capabilities for {t['bundle_id']}", result)
    if any(c.get("attributes", {}).get("capabilityType") == "APP_GROUPS"
           for c in result.get("data", [])):
        return
    st, result = api("POST", "/bundleIdCapabilities", {"data": {
        "type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "APP_GROUPS"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_rid}}},
    }})
    if st not in (200, 201):
        die(f"cannot enable App Groups for {t['bundle_id']}", result)


def profile_content(prof):
    content = prof.get("attributes", {}).get("profileContent")
    if not content:
        st, result = api("GET", f"/profiles/{prof['id']}")
        if st != 200:
            die("cannot read signing profile", result)
        content = result.get("data", {}).get("attributes", {}).get("profileContent")
    if not content:
        die("the profile has no profileContent to install")
    return base64.b64decode(content, validate=True)


def supports_app_group(t, prof):
    """The profile carries the target's App Group and every key in `entitlement_keys`."""
    if "app_group" not in t and "entitlement_keys" not in t:
        return True
    decoded = subprocess.run(["security", "cms", "-D"], input=profile_content(prof),
                             capture_output=True, check=True).stdout
    entitlements = plistlib.loads(decoded).get("Entitlements", {})
    if "app_group" in t and t["app_group"] not in entitlements.get("com.apple.security.application-groups", []):
        return False
    return all(key in entitlements for key in t.get("entitlement_keys", []))


def distribution_cert_ids():
    st, r = api("GET", "/certificates?limit=200")
    if st != 200:
        die(f"ASC certificates query failed (HTTP {st}).", r)
    ids = [c["id"] for c in r.get("data", [])
           if c.get("attributes", {}).get("certificateType") in DIST_TYPES]
    if not ids:
        die("no distribution certificate found in App Store Connect for this team — "
            "cannot build a signing profile.", r)
    print(f"distribution certificates: {len(ids)}")
    return ids


def find_active_profile(t):
    profile_name = t["profile_name"]
    q = urllib.parse.quote(profile_name)
    st, r = api("GET", f"/profiles?filter[name]={q}&limit=1")
    if st == 200 and r.get("data"):
        prof = r["data"][0]
        if prof.get("attributes", {}).get("profileState") == "ACTIVE" and supports_app_group(t, prof):
            print(f"reusing active profile: {profile_name} ({prof['id']})")
            return prof
        # Not active (expired/invalid) — remove so we can recreate cleanly.
        status, result = api("DELETE", f"/profiles/{prof['id']}")
        if status != 204:
            die(f"could not replace stale profile {profile_name}", result)
        print(f"deleted stale profile {profile_name} ({prof['id']})")
    return None


def create_profile(t, bundle_rid, cert_ids):
    profile_name = t["profile_name"]
    body = {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": PROFILE_TYPE},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_rid}},
            "certificates": {"data": [{"type": "certificates", "id": cid} for cid in cert_ids]},
        },
    }}
    st, r = api("POST", "/profiles", body)
    if st not in (200, 201):
        die(f"could not CREATE the {t['label']} profile '{profile_name}' (HTTP {st}) — the "
            "ASC key likely lacks permission. STOP and have the owner mint it.", r)
    prof = r["data"]
    print(f"created profile: {profile_name} ({prof['id']})")
    return prof


def install(t, prof):
    content = profile_content(prof)
    os.makedirs(INSTALL_DIR, exist_ok=True)
    out = os.path.join(INSTALL_DIR, t["file"])
    with open(out, "wb") as f:
        f.write(content)
    print(f"installed {t['label']} profile -> {out}")


def main(names):
    if not names or any(n not in TARGETS for n in names):
        die(f"usage: {os.path.basename(sys.argv[0])} TARGET [TARGET ...] "
            f"with TARGET in {', '.join(TARGETS)} (got: {' '.join(names) or 'none'})")
    global TOKEN
    TOKEN = make_token()
    for name in names:
        t = TARGETS[name]
        bundle_rid = ensure_bundle_id(t)
        ensure_app_groups(t, bundle_rid)
        cert_ids = distribution_cert_ids()
        prof = find_active_profile(t) or create_profile(t, bundle_rid, cert_ids)
        if not supports_app_group(t, prof):
            die(f"Profile for {t['bundle_id']} lacks {t.get('app_group')} or one of "
                f"{t.get('entitlement_keys', [])}. In Apple Developer Certificates, Identifiers & "
                "Profiles, register the App Group and assign it to both com.jerryfane.herdr and "
                "com.jerryfane.herdr.share, and enable Sign in with Apple on com.jerryfane.herdr, "
                "then rerun. No archive was signed with an incomplete profile.")
        install(t, prof)


if __name__ == "__main__":
    main(sys.argv[1:])
