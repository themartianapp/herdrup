# Where the Mac app differs from the iPad references

The references in `agent-list/`, `gram/` and `settings/` are iOS 27.0 iPad simulator screenshots. Herdrup Desktop matches herdrup's regular-width `NavigationSplitView`, which is also the layout the Mac "Designed for iPad" app runs. The Mac app is the same binary, but a few things differ there. Read this before comparing a desktop window to an iPad reference. These captures do not prove Mac rendering, Finder drops or physical-device behavior.

Line numbers are from the head of the pull request that added these files. Search for the quoted code if the lines have moved since.

## Code branches on `isiOSAppOnMac`

| Where | iPad simulator (the references) | Mac "Designed for iPad" |
|---|---|---|
| `App/TerminalHomeView.swift:2280` `agentRosterStack` | `LazyVStack`: rows are built as they scroll into view. | Eager `VStack` (`ProcessInfo.processInfo.isiOSAppOnMac \|\| forceEagerAgentRosterStack \|\| groups.document != nil`). Every row is built up front. The pixels are the same; only the build and scroll timing differ. The iPad switches to the eager stack too once a daemon has folders (`groups.document`), which of the references only `folders` has. |
| `App/SectionTopBar.swift:106-119` `SectionTopBar.body` | Full screen: no window-controls corner, so the bar's row is 44 pt, drawn 6 pt below the bar's top (`windowed ? 0 : 6`). | The window has a corner inset, so `windowed` is true, but `sharesRow` is false because the Mac keeps its traffic lights in their own title-bar row (line 108). The row stays 44 pt but sits at offset 0, 6 pt higher than on the full-screen iPad. |
| `App/SectionTopBar.swift:99`, `:110`, `:140` `containerCornerInsets` | Both corner insets are 0 in full screen, so the "Agents" bar's capsules sit at the 16 pt side padding. | The bar's `leadingInset` and `trailingInset` are the window's `containerCornerInsets` (the traffic-light corner). The capsules and the centred title can move inwards by that inset. [INFERENCE] The size of the Mac's corner inset was not measured here. |
| `App/SectionTopBar.swift:137-139` `backLeads` | Back leads on a full-screen iPad, and on the agent list there is no Back. | Back always leads on Mac (`\|\| ProcessInfo.processInfo.isiOSAppOnMac`). On an iPad *window* it goes to the right-hand capsule instead. |
| `App/TerminalPaneContent.swift:661` | A terminal stream counts as dead after the app was backgrounded. | Counted dead only once it is stale (App Nap). This does not affect the list screens. |
| `App/ComposerView.swift:806`, `App/ConversationColumn.swift:145`, `App/LiveTerminalView.swift:3773` | — | No software-keyboard detection, no column-resize pointer, and indirect (wheel) scrolling. These are pane and chat screens only, not the agent list. |

There are no `targetEnvironment(macCatalyst)` or `isMacCatalystApp` branches in `App/`.

## Window chrome and the traffic lights

- **No status bar on Mac.** The iPad references include iPadOS's status bar, pinned to 9:41, full battery and Wi-Fi (see `agent-list/manifest.json`, `statusBar`). Its height is a safe-area inset above the sidebar's "Agents" bar and the detail column. On Mac the top of the content is the bottom of the window's title bar, and there is no status bar strip. Desktop should compare from below the status bar, or drop it.
- **The title bar and traffic lights** belong to macOS, not to herdrup, and are not in any reference. The iPad references are full screen, where iPadOS 26 draws no window controls. Herdrup reacts to the controls only through `SectionTopBar` (above): it reads the corner inset with `GeometryReader.containerCornerInsets` and passes the window-controls corner down to the split view (`App/TerminalHomeView.swift:1004`, `.environment(\.sectionWindowControls, …)`).
- **Toolbar.** Herdrup draws no system toolbar or navigation bar on either platform: both split columns hide it (`App/TerminalHomeView.swift:909` sidebar, `:988` detail, `.toolbar(.hidden, for: .navigationBar)`). The "Agents" header is herdrup's own `SectionTopBar`. On the Mac the window title bar is the only system chrome.
- **Size and scale.** The references are 1376×1032 pt and 1180×820 pt at @2x. A Mac window can be any size within the app's limits. [INFERENCE] Not verified here: whether macOS scales "Designed for iPad" content (point-to-pixel ratio) on a given display. Compare in points.

## Pointer and hover

A Mac always has a pointer. The iPad simulator under XCUITest only has touches, so none of these appear in a reference:

- **Hover highlights** (`.hoverEffect(.highlight)`): the sidebar tab bar's Agents/Gram/Settings items (`App/TerminalHomeView.swift:1329` `sidebarTabItem`), the hide-sidebar toggle (`:1378` `sidebarToggleButton`), the minimised rail's buttons (`:1493` `railSectionButton`), the Settings index rows (`App/SettingsView.swift:936`), the Gram sidebar rows (`App/TerminalHomeView.swift:1219`), the "Agents" bar's buttons (`App/SectionTopBar.swift:213` `SectionBarButton`), the sidebar search field (`App/InlineSearchField.swift:116`) and the session pills (`App/SessionPills.swift:92`).
- **Roster row hover** (`App/TerminalHomeView.swift:2695`, `.onContinuousHover`): hovering an agent row makes that agent type its line into the empty detail column's glyph field at the row's height. Nothing in the sidebar changes.
- **Glyph field** (`App/SelectAgentField.swift:206`, `UIHoverGestureRecognizer`; `:375` `hovered`; `:411`): with no pointer the field runs a slow "ghost" autopilot lens, plus a twinkle and typing writers. On Mac a real pointer drives the lens, and a click does not end hovering (`.indirectPointer`). In the references the field is held still: one resting picture from a fixed seed (`DesktopReferenceMock.glyphFieldSeed`, SplitMix64 through `FieldDice`), with no lens, twinkle or writers. On both platforms the live field is animated and random by design. Only the "Select an agent" label and the field's resting look can be matched pixel for pixel.

## Motion held still in the references

These are not Mac differences, but they matter in any comparison. The references freeze things that move in the app on both platforms:

- The working ring (`TurningRing`, `App/DesignSystem.swift`) is drawn at rest. In the app it turns once every 0.9 s.
- The loading spinner is frozen on its first frame (the window's layer speed is set to 0 in the `loading` state only).
- UIKit and SwiftUI animations are off, so the Idle and Archived rows open instantly.
