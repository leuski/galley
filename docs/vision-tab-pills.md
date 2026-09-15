# Vision Tab Pills: a gaze-revealed, axis-agnostic tab strip

Design for the visionOS tab-switching control. Galley has no
tab-switching UI on visionOS today — `DocumentSceneContent` mounts every
tab in a `ZStack` and switches by opacity, so all that is missing is the
chrome. Dot ships a working precursor (`VisionTabPill` +
`VisionTabOrnament`), but it is horizontal-only, welded to Dot's
`WindowModel`, and its compact state is effectively `EmptyView()`
because a separate top bar serves as the reveal trigger.

The control described here is **generic and lives in `KosmosAppKit`**,
so Galley and Dot use one implementation. Galley mounts it vertically on
the trailing edge; Dot keeps its horizontal top placement.

## The constraint that decides the design

Gaze runs out-of-process. The app cannot read it as a `Bool`: `onHover`
is pointer-only and never fires for gaze, and a hover effect's active
state is not observable state. The only reveal mechanism is
`hoverEffect` / `HoverEffectGroup`, which applies a small set of
render-time modifiers (`clipShape`, `opacity`, `scale`) **after** layout
has run.

> The expanded form is always what gets laid out. "Compact" is the
> expanded view with a clip over it.

Everything below follows from that. In particular, no design where
collapsing actually reflows the strip is available, and the strip's
footprint inside the ornament is always expanded-sized.

## Decisions

### Expand the whole collection at once

One `HoverEffectGroup` shared by every pill. Gaze on any member
activates the group and all pills expand together.

The user task is *scan the list, pick one* — per-pill expansion turns
that into serial gaze work. More importantly it solves the vertical
case: Dot's horizontal strip has a top bar acting as the reveal trigger,
but a vertical column has no such bar, so the collection has to be its
own trigger. A shared group is exactly that.

Membership must be **explicit** — `hoverEffect(in:)` on each pill, never
the `hoverEffectGroup(in:)` modifier form. The modifier form adds the
group to every effect on descendant views, which sweeps the pills' own
`.highlight` effects into the group and breaks per-pill highlighting.
Dot hit this and records it in `VisionTabOrnament.swift`.

### Independent pills with gaps, not one bar

A single bar wants a background that grows and shrinks, which fights the
clip: Dot had to match the reveal clip's corner radius to the glass
background exactly, because a plain rectangular clip squared the corners
in the collapsed state. Independent capsules collapse to a row/column of
glass circles — legible, idiomatic, and no large opaque slab hanging off
the window edge. The cost is N glass backgrounds instead of one, which
is not a concern at realistic tab counts.

### Uniform pill extent, fixed by metrics

All pills share one cross-axis extent when expanded and one when
compact, both fixed point values in `TabPillMetrics` rather than
measured from content. Ragged edges on a floating column read as noise,
one extent gives the whole group a single animation, and the clip-based
reveal needs known geometry anyway. Titles truncate in the middle past
the cap.

Content-tailored widths buy nothing: the compact extent is a circle
regardless.

### Growth direction is a parameter

The compact pill holds still and the expansion moves one edge. Default
is **away from the window**: the clip is anchored on the pill's
window-facing side, so expanding never grows over window content.
Ornaments float in front of the window, so growing inward would occlude
the page.

Dot's existing bar does the opposite — its main row is pinned farthest
from the window and the tab row appears beneath it, toward the window —
so the direction is a parameter (`.awayFromWindow` default,
`.towardWindow`), not a constant.

### Placement: fixed-point gap, never a fractional anchor

The strip attaches as an `.ornament` at a scene edge anchor, with a
transparent, non-interactive spacer between it and the window edge. The
gap is what makes revealing require *deliberate* gaze — the pills sit in
empty space, not against the window chrome.

The spacer must be a fixed point size. A fractional `UnitPoint` anchor
scales with the window and the gap would drift as the window resizes.
Dot's `floatGap` (constant spacer inside the ornament content) and
`resultsSpacer` (spacer derived so that center alignment lands the panel
a fixed distance off the edge) are the two worked examples; the
derivation is per-edge and has to be redone for each, which is
mechanical but not copy-paste.

## Anatomy

```
TabPillStrip(axis:edge:growth:metrics:)
  ├ stack along `axis`, spacing = metrics.spacing
  ├ per item: ZStack { compact; expanded } in a Capsule,
  │           .glassBackgroundEffect, sized to metrics
  ├ all pills: .hoverEffect(in: sharedGroup) { clipShape(capsule sized
  │            to compact when inactive, full when active, anchored on
  │            the window-facing side) }
  ├ optional trailing accessory slot (host-supplied; group member)
  └ fixed transparent gap spacer on the window-facing side
```

**Expanded pill (host-supplied).** For Galley: document title
(semibold, one line) over file name (caption, secondary). Active pill
filled `.tint`, others `.thinMaterial`. A close affordance on the active
pill only — always laid out at `opacity(0)` and `allowsHitTesting(false)`
when hidden, never conditionally inserted, so every pill keeps the same
extent. Dot learned this one the hard way; conditional insertion made
inactive pills shorter because the button drove the height.

**Compact pill (host-supplied).** A circle with initials, same
active/inactive fill rule so the active tab stays identifiable while
collapsed. Initials rule: one character; if any two items in the
collection collide on their first character, promote **the whole
collection** to two. Uniform beats per-item cleverness.

**Ownership seam.** The strip owns layout along the axis, the shared
hover group, the clip geometry, uniform extent, and the gap. It knows
nothing about selection, closing, or tinting — those live in the host's
`compact:` / `expanded:` builders, which is what lets Dot's pills carry
a close button and Galley's carry a two-line label without the strip
growing options for either.

## API sketch

```swift
// KosmosAppKit, visionOS only.

public struct TabPillMetrics: Sendable {
  public var compactExtent: CGFloat      // cross-axis, collapsed
  public var expandedExtent: CGFloat     // cross-axis, revealed
  public var thickness: CGFloat          // along-axis size of one pill
  public var spacing: CGFloat            // between pills
  public var gap: CGFloat                // strip to window edge
  public var revealDelay: TimeInterval   // dwell before opening
  public var holdDelay: TimeInterval     // hold open after gaze leaves
  public var duration: TimeInterval

  public static let `default`: TabPillMetrics
}

public enum PillGrowth: Sendable { case awayFromWindow, towardWindow }

public struct TabPillStrip<Item, Compact, Expanded, Accessory>: View
where Item: Identifiable, Compact: View, Expanded: View,
      Accessory: View
{
  public init(
    _ items: [Item],
    axis: Axis = .vertical,
    edge: Edge = .trailing,
    growth: PillGrowth = .awayFromWindow,
    metrics: TabPillMetrics = .default,
    @ViewBuilder compact: @escaping (Item) -> Compact,
    @ViewBuilder expanded: @escaping (Item) -> Expanded,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() })
}

extension View {
  /// Attaches a strip as a scene-edge ornament with the fixed gap
  /// spacer already applied.
  public func tabPillOrnament<S: View>(
    edge: Edge, @ViewBuilder strip: () -> S) -> some View
}
```

`gazeReveal` (currently Dot-local, `UI/vision/HoverEffect.swift`) moves
to `KosmosAppKit` alongside this — it is the generic
`hoverEffect` + per-direction animation wrapper both hosts need.

## Host adoption

**Galley** — vertical, trailing edge, growth away from the window.
Items are `WindowModel.tabs` (`[DocumentModel]`); active is
`window.activeTab`; tap calls `window.activate(tab:)`, close calls
`window.close(tab:)` (which already refuses the last tab). Mounts on the
same view that owns the window body, next to the existing top-edge
toolbar ornament, so the two never contend for an edge. Strip mounts
only at two or more tabs — that policy stays with the host, not the
control.

No new-tab affordance in v1. Dot puts its `+` in the top bar; Galley can
fill the optional accessory slot later with a `.fileImporter` trigger if
in-window multi-document opening turns out to matter on AVP.

**Dot** — horizontal, top edge, growth toward the window, accessory
empty (its `+` stays in the existing bar). Migration replaces the
`tabStrip` computed property and the `gazeReveal` clip inside
`VisionTabOrnament`; `VisionTabPill` becomes the `expanded:` builder
plus a new one-glyph `compact:` builder. Dot's current strip also has a
share-equally-then-scroll behavior that this control does not reproduce
— fixed extent plus overflow is the replacement, and whether Dot needs
scrolling past N tabs is an open question below.

## Accessibility

- Every pill carries an identifier and an active/inactive value, as
  Dot's do (`ViewerA11yID.tab(index)` / `.tabClose(index)`); Galley's
  `ViewerAccessibilityIdentifiers` needs the same two entries added.
- Under `accessibilityReduceMotion`, drop the animation but keep the
  reveal — the clip still switches, without the spring.
- VoiceOver must reach every tab regardless of clip state. The clip is a
  visual effect; confirm the collapsed pills still expose their expanded
  label, and if not, supply an explicit `accessibilityLabel` on the
  container.

## Must verify before building

1. **Does a hover-effect `clipShape` clip hit testing, or only
   rendering?** If the expanded footprint stays gaze-active while
   invisible, looking at empty space beside the window pops the strip
   open, which destroys the deliberate-gaze property the gap exists to
   create. Fix would be `.contentShape` over the compact footprint only.
   Dot never hit this because its collapsed row lives inside an
   already-visible bar. Confirm on device; do not reason about it.
2. **Per-edge ornament spacer math.** Only the top-edge derivation
   exists (Dot). Leading/trailing/bottom need their own, verified
   against a resizing window.
3. **Minimum gaze target size** for the compact circle — check the
   current visionOS HIG figure rather than carrying over a macOS
   assumption.
4. **Glass cost** with N independent `glassBackgroundEffect` capsules
   floating in the ornament layer.

## Non-goals

- Drag to reorder tabs.
- Scrolling / overflow beyond a fixed pill count (revisit once either
  host has a real multi-tab workload).
- Any macOS use. macOS windows have native AppKit tabbing; this control
  is visionOS-only and guarded `#if os(visionOS)`.
