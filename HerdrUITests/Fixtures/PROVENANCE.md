# Vendored fixtures

## desktop-reference-agents.json

A byte-for-byte copy of Herdrup Desktop's fake herdr roster. It is an `agent.list` result with the top-level keys `type` and `agents`.

- Repository: [jerryfane/herdrup-desktop](https://github.com/jerryfane/herdrup-desktop)
- Path: `cmd/fakeherdr/agents.json`
- Commit: `0b5111ed47fb2325f6caf4a383758209c6d6c9f6`
- sha256: `f912df090a009597e326cc7df873addc242be2400e8645f5c654c2b168a081e2`

`DesktopReferenceShots` checks the sha256 before every launch. It passes the bytes to the app in `HERDR_DESKTOPREF_AGENT_LIST`, and the `desktopref` screenshot mock serves them unchanged as the `result` of `agent.list`. The references under `design/reference/agent-list/` are drawn from this file. Do not edit it here: update it from the desktop repository, then update the commit, the sha256 (here, in the test and in the manifest), and the references.

## desktop-reference-<state>.json and desktop-reference-avatar.png

Written here, for the served reference states, and copied byte for byte to Herdrup Desktop so its fake herdr serves the same data (`/root/fleet-tools/state/herdrup-desk/reference-states-fixtures/`). Each file is one JSON object: `state`, then every answer the state gives, keyed by what it answers.

- `ping`, `agent.list`, `agent.groups.get`: that method's `result`.
- `agent.avatar.get`: the `result` for each picture, keyed by its sha256 (the request's `params.sha256`).
- `herdr session list --json`: that command's output on the machine.
- `agent.list in session`: the `agent.list` result of each other running session, keyed by session name (`herdr --session <name>`).

A method a state has no key for is refused as `unknown_method`.

| File | sha256 |
|---|---|
| `desktop-reference-folders.json` | `7688f3779c18e297213dd1248be390728857c228460aa6ae04cf70b06650cf84` |
| `desktop-reference-avatars.json` | `1dcc6889466fecc87efd23bca7bc2dee6cdde450a4e75d601a7e5a28eb879592` |
| `desktop-reference-sessions.json` | `e600054d6595f7df0abeb3ed56cfa3f346c919cf093a18c32f9f20226dd328bd` |
| `desktop-reference-federated.json` | `0445d1690258871aac0048c1c9f77f71dfe0476808738fbc6744eb641ae1c2ad` |
| `desktop-reference-needs-you.json` | `101ad2cba65a1a12b77ed32ae3bfbbf13da2a34d90b5a75d9021a5bcfaee2856` |
| `desktop-reference-avatar.png` | `e4d4139d5914062cd06d5b6cbd8ade1d5fddf83c20ee575d4d83b8d81de38a4a` |

`desktop-reference-avatar.png` is atlas's uploaded picture in the avatars state: a 256×256, 16-colour PNG of 559 bytes (a sunset over water). `desktop-reference-avatars.json` carries the same bytes as base64 under that sha256, and `DesktopReferenceShots` checks both before the launch. Like the roster above, change these only together with the sha256 here, in the test and in the manifest, and the references.

## desktop-reference-detail.json

Synthetic capture inputs for `DesktopDetailReferenceShots`, sha256
`38f1ec400fd95f3c6229d7390e157c9c7b42acc246387093ce01e478ab5e887a`.
The file supplies quiet-mock environment flags, an unsent writer draft and three
reserved `.example.invalid` saved-host metadata rows. Host metadata is supplied
through the launch argument domain; no Keychain entry or SSH connection is created.

These screenshots use the real `chatview` and `onboarding` surfaces, not the
control/resize harness. The transcript and terminal output are built-in fixtures
in `App/ChatMockTranscript.swift` and `MockTransport` at the image's recorded source
commit; this JSON is not claimed to contain that daemon output. Chat fixture dates
and separators honor the pinned clock. The writer's software keyboard is dismissed
through its real Collapse keyboard action before collapsed/expanded capture.

Run `ONLY_SUITE=DesktopDetailReferenceShots ONLY_DEVICE=ipad Tools/ci/ui-shard.sh focused`
on a Mac (docs/DESIGN.md "CI") for both reference sizes. It exports Chat, Terminal,
collapsed writer, expanded writer and
saved-host selection images. The saved-host chooser is connection home, not the
Settings federation list or a fabricated connected-host dropdown.

Run [41049693045](https://github.com/themartianapp/herdrup/actions/runs/41049693045)
at `1c21ad11929d6111ae578166e9f39e64f6abc3fd` passed all three capture cases on each
iPad (six executions, zero failures/skips). The ten original exported PNGs are in
[`design/reference/detail`](../../design/reference/detail/manifest.json), with
per-image source, input and PNG hashes, dimensions, native mock route and conditions.
All ten images were visually inspected. The app clock is pinned; the system status
bar date is the runner's actual Fri Oct 30. The earlier 54 PNGs are unchanged.

