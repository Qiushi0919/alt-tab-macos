# Appearance (window sizing) — Specs

> **Line coverage:** `AppearanceTestable.swift` 79% · _refreshed 2026-05-27 by `/coverage-explore`_

## Summary

Two pure sizing functions in `AppearanceTestable` decide how big the switcher's thumbnails are on a
given display, so the UI feels right from an 11" laptop to a 60" TV. The suite pins their output against
a table of **21 real device models** (laptops, monitors, ultrawides, TVs) with known pixel + physical
dimensions, so a tweak to the formula can't silently regress any class of screen.

- `comfortableWidth(physicalDimension)` → the fraction of the screen the switcher should occupy (smaller
  fraction on bigger/wider screens, separate expectations for horizontal vs vertical use).
- `goodValuesForThumbnailsWidthMinMax(ratio, rowCount)` → the (min, max) thumbnail width for a given
  screen aspect ratio and row count (3, 4, or 5 rows).
- `indicesGroupedByDisplay(displayIndices, fallbackDisplayIndex)` → a stable display grouping that
  preserves the selected MRU/alphabetical/Space order inside each display.
- `startsNewDisplayRow(previous, current, enabled)` → whether the tile layout must begin a new row at
  a display boundary when the all-displays mode is active.
- `startsDisplayGroup(previous, current, enabled)` and `displayGroupTitle(...)` → every display group,
  including the first, receives a small heading such as `Display 2 · All Spaces`.
- `shouldRetryMirrorSnapshot(failedAttempts, maximumAttempts)` → a newly shown panel may retry a
  not-yet-composited WindowServer snapshot, but the retry loop is always bounded.

## Behavior & edge cases

- Driven entirely by a fixture table: each row is `(model, pixels, physical-mm, expected comfortable
  fractions, [(rowCount, expectedMin, expectedMax)])`. Both tests loop the table and assert with `0.01`
  tolerance, naming the failing model.
- Bigger physical screens get a smaller comfortable fraction (a 60" TV shouldn't show a half-screen
  switcher); ultrawides get distinct horizontal vs vertical fractions.

## Test scenarios

Mirrors `AppearanceTests.swift` 1:1.

- **testGoodValuesForThumbnailsWidthMinMax** — for every model × {3,4,5} rows, the computed (min, max) thumbnail width matches the fixture.
- **testComfortableWidth** — for every model, the comfortable width fraction matches for both horizontal and vertical screen use.
- **testComfortableWidthFallsBackToDefaultWhenPhysicalWidthIsNil** — when the screen's physical dimensions aren't reported, fall back to the 0.9 default rather than the 0.45 floor.
- **testGoodValuesForThumbnailsWidthMinMaxPortrait** — for aspectRatio < 1 (portrait usage), the (min, max) uses the portrait formula and stays within the [0.09, 0.30] clamps.
- **testIndicesGroupedByDisplayPreservesOrderWithinEachDisplay** — display grouping is stable and puts
  display 1 before display 2.
- **testIndicesGroupedByDisplayCanAssignWindowlessAppsToTriggeredDisplay** — a windowless app uses the
  triggered display as its fallback group.
- **testStartsNewDisplayRowOnlyAtAnEnabledDisplayBoundary** — rows split only when all-displays mode is
  enabled and the visible display group changes.
- **testDisplayGroupStartsAtTheFirstWindowAndEveryDisplayBoundary** — the first visible display and each
  following display boundary get exactly one heading.
- **testDisplayGroupTitleIncludesDisplayNumberAndSpaceScope** — headings include both the display number
  and the shortcut's current Space scope.
- **testMirrorSnapshotRetriesAreBounded** — first-show mirror retries stop after the configured limit.
