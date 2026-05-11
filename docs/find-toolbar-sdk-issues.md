# Toolbar-Based Find: Design, Issues, and Required SDK Fixes

State of play (macOS 26 / SwiftUI build current as of 2026-05-11): an
expanding "find" item in the document toolbar — collapsed to a
magnifying-glass icon, expanding in place to a full search field on
click — cannot be built on top of SwiftUI's current toolbar bridge.
Galley shipped a working prototype and then removed it. This document
records the design, why it broke, and the smallest plausible SDK
changes that would unblock it for a future macOS release.

## Intended design

- A toolbar item that swaps between two visual states:
  - **Closed**: bare magnifying-glass `Button`, identical chrome to
    sibling icon items.
  - **Open**: rounded text-field pill, ~180–350pt wide, with inline
    options menu, "n of N" counter, and clear button.
- Toolbar items adjacent to it (renderer / template / reload) cede
  space when the field expands; they overflow to the chevron menu
  before the field does.
- ⌘F, ⌘E, and the Edit menu drive the same surface.
- When the window is too narrow or the item has been customized away,
  fall back to a slide-down `FindBar` strip below the toolbar.

This is Preview / Mail / Finder behavior, and AppKit has the building
blocks for it (`NSToolbarItem.visibilityPriority`, Auto Layout width
constraints on `item.view`, `NSSearchToolbarItem`). The shipping
problem is the SwiftUI-to-AppKit bridge that sits between the
`.toolbar(id:)` modifier and the live `NSToolbar`.

## What we built and why we removed it

The implementation hosted a stable `ZStack` of (search-field,
magnifying-glass-button) inside a single `ToolbarItem(id: "find")`. A
companion `ToolbarSurfacing` actor observed `NSWindow.toolbar` /
`NSToolbar.isVisible` / `NSToolbar.visibleItems` / item-add and
window-resize notifications, re-pinned the find item's
`visibilityPriority` to `.user` and its siblings' to `.low`, and
installed width constraints (`compactWidth` when closed, an
`expandedMinWidth … expandedMaxWidth` range when open) on
`item.view`.

It worked when the field was focused. It failed when the user gave a
non-empty query and clicked away.

The whole apparatus (`ToolbarSearchField`, `ToolbarSurfacing`, plus
the `AppKitSearchField` `NSTextField` wrapper it forced) has been
removed. Find is now FindBar-only.

## What actually went wrong, by evidence

Instrumented logs (see commit history if needed) showed three
distinct problems, all rooted in SwiftUI's toolbar bridge:

1. **SwiftUI rebuilds `NSToolbarItem` instances on body re-renders.**
   When the focus state of an item's content view changes, the bridge
   re-creates the underlying `NSToolbarItem` and `NSToolbar` reflows
   with default priorities — every `visibilityPriority` we set was
   reset to `0` before the next reflow ran. The find item we pinned
   to `.user` (2000) showed up at `0` in the priorities-before
   snapshot taken on the very next refresh. The sibling items SwiftUI
   adds itself (`navigationSplitView.toggleSidebar`,
   `splitViewSeparator-0`) keep their priorities; only items the
   bridge rebuilds lose them.

2. **`NSToolbar`'s KVO surfaces don't fire for layout-only
   reflows.** `\.visibleItems`, `\.isVisible`, `willAddItem`, and
   `didRemoveItem` were registered and never fired during the
   focus-loss reflow that moved find to overflow. Only
   `NSWindow.didResizeNotification` fired, and only on actual user
   resizes — not on the silent reflow triggered by the focus change
   itself. The state-machine had no signal to react to.

3. **`window.toolbar` cannot be swapped under SwiftUI without
   crashing.** Replacing `window.toolbar` with one we own raises
   `NSRangeException` from `SwiftUI.BarAppearanceBridge` on the next
   layout pass: the bridge holds an `addObserver:forKeyPath:
   displayMode` registration against the toolbar SwiftUI created
   and, when `AppKitWindowController.updateToolbarIfNeeded` runs,
   calls `removeObserver:forKeyPath:displayMode` on whatever
   `window.toolbar` returns now — our instance, where the bridge
   never registered. The crash fires from the very first
   `NSHostingView.updateConstraints` and is unrecoverable.
   `NavigationSplitView` plus the `.toolbarBackgroundVisibility` /
   `.containerBackground(..., for: .window)` modifiers wire up
   `AppKitWindowController`'s toolbar tracking; `.toolbar(id:)` is
   not the only trigger.

Sam Rowlands filed
[FB17392294](https://ohanaware.com/swift/macOSToolbarExamples.html)
describing the converse symptom — sibling toolbar items getting
trapped in the chevron when an adjacent search field gains and loses
focus. Same root cause, opposite victim.

## What we tried and why each failed

- **`visibilityPriority = .user`** on find, `.low` on siblings.
  Priorities are reset by problem (1) faster than we can re-pin them.
- **Re-pinning aggressively on every observed signal.** Observed
  signals (problem 2) don't fire during the relevant reflow.
- **Owning the `NSToolbar` ourselves via an `NSToolbarDelegate`
  installed in `WindowAccessor.onAttach`.** Spike crashed immediately
  per problem (3). Coexistence with SwiftUI's `AppKitWindowController`
  toolbar tracking is not viable.
- **Reordering find to be first in the toolbar** (Sam's workaround).
  Helps the sibling-overflow shape Sam reported. Does nothing for our
  shape (find itself losing priority on rebuild).
- **`.searchable(text:placement:)` + `searchToolbarBehavior(...)`.**
  `searchToolbarBehavior.minimize` — the variant that renders the
  field as a button-like control until tapped — is iOS / iPadOS /
  Catalyst / visionOS only. macOS 26 has the `SearchToolbarBehavior`
  type, but only `.automatic` is available on it. There is no native
  macOS API for the "minimize to icon, expand on click" behavior
  even though Apple ships it everywhere else.

## What an SDK fix would look like

In rough order of how surgical it would be:

1. **Make `.minimize` (or an equivalent) available on macOS 26.x.**
   This is the actual ask. Mail, Finder, and Preview do this with
   `NSSearchToolbarItem`; SwiftUI on macOS just doesn't expose it.
   Most direct path: lift the macOS availability gate on
   `SearchToolbarBehavior.minimize`, backed by `NSSearchToolbarItem`
   under the hood. Galley would drop its custom toolbar item entirely
   and use `.searchable(...)` + `.searchToolbarBehavior(.minimize)`.

2. **Preserve `NSToolbarItem.visibilityPriority` across SwiftUI
   item-rebuilds.** If SwiftUI must rebuild items on re-render, the
   bridge should at minimum copy the previous instance's
   `visibilityPriority` to the new one. Even better: expose a
   `.visibilityPriority(_:)` modifier on `ToolbarItem` so the value
   becomes part of the SwiftUI item description and survives rebuilds
   without app-side observation.

3. **Make `NSToolbar`'s overflow transitions observable.** Either fix
   `\.visibleItems` KVO so it actually fires on layout-only reflows
   between `items` and overflow, or post a dedicated notification.
   FB17392294's symptom and ours both stem from layout decisions the
   app cannot react to because nothing tells it they happened.

4. **Tolerate `window.toolbar` replacement.** `BarAppearanceBridge`
   should hold its observer registration against the toolbar it
   actually registered on (weakly), not the toolbar `window.toolbar`
   currently returns. The current pattern means once SwiftUI has
   touched the window, no AppKit code can ever swap the toolbar
   without crashing — which closes the only escape hatch when the
   bridge's behavior diverges from what the app needs.

(1) alone solves Galley's actual goal. (2) and (3) would let app
authors keep building custom toolbar items the way the AppKit-era
docs say they should. (4) is the safety net.

## Re-enabling the design after a fix

Files removed from the prototype branch:
- `Sources/Viewer/Views/ToolbarSearchField.swift`
- `Sources/Viewer/Models/ToolbarSurfacing.swift`
- `Sources/Viewer/Views/AppKitSearchField.swift`

If fix (1) ships, none of those come back. The path is
`.searchable(text: $model.find.query, placement: .toolbar)` on the
detail view, `.searchToolbarBehavior(.minimize)` after it,
introspection of the live `NSSearchToolbarItem` (per
[siteline/swiftui-introspect#397](https://github.com/siteline/swiftui-introspect/discussions/397))
only if we still need the inline options menu / counter. FindBar
stays as the always-available fallback for ⌥-⌘-T (toolbar hidden)
and the customize-toolbar-out case.

If fix (2) or (3) ships without (1), the prototype files can be
restored from git and the corresponding workaround removed.
