# Settings references for Herdrup Desktop

Four states on each reference iPad (eight PNGs), captured through proposal-B Settings. These show the real regular-width index/detail split; they are not Mac screenshots or live connection evidence.

| State suffix | Visible reference |
|---|---|
| `settings-machines-index` | Settings index at its top; connected-machine card and Machines detail hero |
| `settings-machines-federation` | All six saved-machine states, unsaved guest peer, add-machine action and summary |
| `settings-machines-empty` | Connected host with no saved machines and the add-machine guidance |
| `settings-about-index` | HELP and ABOUT rows in the scrolled Settings index, with Machines still in the detail column |

ABOUT is an inline index section, **not a separate detail page**. On the 11-inch iPad, the top/index capture does not fit every federation row; the federation capture scrolls the detail column to show the complete list. The index remains independent.

## Machine fixture

The synthetic connected host is `reference-hub`; no SSH connection is made. The populated fixture, `HerdrUITests/Fixtures/desktop-reference-settings-machines.json`, serves:

| Machine | State |
|---|---|
| atlas-mini | Reachable, two agents |
| birch-air | Degraded, one agent |
| cedar-linux | Offline, one agent |
| delta-nas | Disabled |
| ember-box | Coordinator off |
| fjord-laptop | Not federated (stale) |
| guest-lab | Unsaved reachable peer, one agent |

The unsaved peer has no saved-machine federation control. The empty capture uses `desktop-reference-settings-empty.json`.

`manifest.json` records each PNG's hash, actual capture head/run, fixture hash, device, dimensions and observed capture conditions. Six were produced by run [41019198405](https://github.com/themartianapp/herdrup/actions/runs/41019198405) at `4b577c1aaca565646bc2ebd0c0c6695e9972b0f5`; both device rounds passed all three capture methods. One method captures both the top and federation positions. The two `settings-machines-federation` PNGs were recaptured at `cda456e8df087039d5202f2e86369d31b8824c60` (11-inch: run [41341195776](https://github.com/themartianapp/herdrup/actions/runs/41341195776); 13-inch: run [41341282823](https://github.com/themartianapp/herdrup/actions/runs/41341282823)) when federation machine chips became circles (owner, 2026-11-01). Only the chip column and the status-bar date differ from the earlier capture.

The shared contract is iOS 27.0, dark landscape @2x, Large Dynamic Type, en_US/UTC/Gregorian and mock clock `2026-10-28T09:41:00Z`. The system status bar shows the runner's real date at overridden 9:41: Fri Oct 30, except Mon Nov 2 on the two federation PNGs. Deliver these with the same-runtime [agent-list](../agent-list/) and [Gram](../gram/) sets. See [regeneration](../agent-list/README.md#regenerating) and [Mac differences](../MAC-DIFFERENCES.md).
