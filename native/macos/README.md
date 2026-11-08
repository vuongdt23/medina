# Adaptive playback workspace

## Engine rollout

The native macOS app and `MedinaPlayback` target require macOS 15 and use
libmpv through a small C interoperability target. Install the Homebrew `mpv`
formula (which provides `libmpv` and its dependencies) before building. The
player owns one libmpv client/render context and Medina-owned controls. External
subtitle sidecars are attached as libmpv subtitle tracks. System PiP is not
enabled.

The native app requires Xcode 26.4 / Swift 6.3 or newer. `pkg-config mpv` must
resolve in the build environment. Swift language mode remains Swift 6.

The native macOS course workspace adapts to **window space in logical points**,
not display resolution. The app supports windows down to 480 × 360 pt.

## Settings and diagnostics

Open app-wide settings from the gear button in either workspace or the standard
Settings command (⌘,). Logging enablement, minimum Debug/Info level, and
persistent file logging are stored in UserDefaults. When file logging is
enabled, logs are kept under `~/Library/Logs/Medina/`; the Settings window can
open or clear them.

## Layout

- **Wide (1,200+ pt):** resizable 300–480 pt course sidebar and playback.
- **Standard (850–1,200 pt):** sidebar clamped to leave a usable player pane.
- **Compact (under 850 pt):** playback-first, with temporary course navigation.
  Navigation is a drawer at 600+ pt and a full-width content view below 600 pt.
- Threshold hysteresis prevents repeated transitions during live resizing.
- Short windows (under 540 pt tall) omit the resume card and secondary player
  metadata; typography stays readable and primary controls remain available.
- libmpv's embedded OpenGL surface uses aspect-fit rendering and preserves
  video content, including instructional text.

The outline and playback inspector retain their SwiftUI identity across layout
changes. `LibraryModel` continues to own the libmpv playback session. Progress reporting belongs
to the course workspace, so it continues while a supporting file is open.

Sidebar width, Focus mode, outline density, and auto-play preference are saved
locally. A temporarily clamped width never replaces the user's preferred width.
Automatically hiding navigation in compact mode does not overwrite Focus mode.
Focus mode hides navigation and uses dark appearance in non-compact windows.

## Navigation and playback

- **⌘F:** open course content and focus lesson search. Search matches lesson
  titles and section ancestry, preserving playback order and section context.
- **⌃⌘S:** show/hide course content.
- **⌘← / ⌘→:** previous/next lesson.
- **Escape / Done:** dismiss compact navigation.
- **Scope button:** explicitly scroll to the current lesson. Playback changes
  expand its ancestor sections without continually stealing the scroll position.
- Comfortable rows wrap to two lines; the density menu offers compact rows.
- Selection has a warm surface; the active lesson has a play glyph and amber
  edge. Completed lessons use checks; partial progress uses a small ring.
- Section cards use numbered headers, restrained borders, and a warm highlight
  for the current section. Nested sections avoid stacked card backgrounds. A
  header has just one action: expand/collapse; selecting a lesson starts playback.
- Medina supplies play/pause, seeking, volume, speed, audio/subtitle menus, and
  embedded libmpv rendering. Its edge-to-edge OSC uses a video scrim, lesson
  context, a full-width timeline, warm-accent transport controls, and transient
  feedback; playback options move into an adaptive popover on compact windows.
  The footer adds only previous/next **lesson** navigation and an auto-next
  switch; it is not a duplicate transport bar.
- The Continue/Resume card appears only before a playback session is active.
- With auto-play disabled, natural EOF shows completion; use the play button to replay.

## Seek previews

Hover or drag the playback timeline to see a timestamp and an on-demand frame.
The native client uses a separate AVFoundation image generator, never seeking or
snapshotting the active libmpv player. No server thumbnail endpoint, external
ffmpeg tool, or pre-generated storyboard is required.

Requests are quantized to one-second buckets, with one decode in flight and only
the newest pending target retained. A per-lesson, 60-image LRU cache avoids repeat
work. Old results cannot replace the currently requested frame, and lesson
changes invalidate the cache. While a frame is decoding the preview card shows
“Loading preview…”; failures show “Preview unavailable” plus the timestamp and
are reported through playback diagnostics. Leaving the timeline cancels work
cooperatively; any active AVFoundation decode drains before another request can
start.

Controls remain visible while hovering or scrubbing. The seek bar overlays libmpv's
cached, seekable time ranges ahead of the playhead; only ranges reported as
actually seekable by the demuxer are shown. Dragging changes the local thumb and
preview only; releasing commits a single playback seek. Native slider keyboard
and accessibility adjustments still seek immediately.

This borrows thumbfast's on-demand scheduling model, not its persistent mpv
helper. Thumbnail extraction is handled separately from libmpv playback;
latency and extra HTTP-range traffic depend on the media and network.

## App icon

The Medina Station artwork is preserved in `Artwork/AppIcon.png`. The app uses
an `AppIcon` asset catalog containing all ten standard macOS/Retina sizes. The
prepared icons have transparent outer margins and retain the artwork's shadow.

To regenerate the assets, run from the repository root:

```sh
swift native/macos/tools/generate-app-icon.swift \
  native/macos/Artwork/AppIcon.png \
  native/macos/Medina/App/Resources/Assets.xcassets/AppIcon.appiconset
make macos-build
```

The background-removal step is specific to this dark tile on a white canvas;
keep the original artwork if preparing a different icon design. Xcode compiles
`AppIcon.icns` and the asset catalog and supplies the bundle icon metadata.
Relaunch the application after rebuilding to refresh its Dock icon.

## Verification

Automated: `make macos-test` covers layout thresholds/hysteresis, sidebar clamping,
lesson search ancestry/order, playback speed bounds/persistence, and thumbnail
scheduling/cancellation/cache isolation (including a real AVFoundation frame extraction).
Build the native application with `make macos-build`.

To check the actual decoder against a remote lesson without starting playback:

```sh
cd Packages/MedinaPlayback
MEDINA_PREVIEW_TEST_URL='http://server:17843/api/v1/lessons/ITEM_ID/content' \
MEDINA_PREVIEW_TEST_TIME=41 \
swift test --filter testRealThumbnailLeavesPlaybackSessionIdle
```

Without these environment variables, that test uses the repository's local MP4
fixture. This HTTP check complements, rather than replaces, the live UI checks.

Manual acceptance checklist (requires the app and playable course media):

1. Play a lesson and resize from 1,600 → 1,000 → 750 → 480 pt, then back. Audio
   and playback position must continue, without reloading the lesson.
2. Drag around 820–880 pt and 1,160–1,200 pt; navigation must not flicker.
3. Tile to half-screen and a short quarter-screen-sized window. Verify readable
   titles, reachable controls, independent outline scrolling, and uncropped video.
4. Move between Retina/non-Retina displays and an ultrawide screen.
5. Change sidebar width, shrink the window, then widen it. Restore the preferred
   width. Toggle Focus mode, shrink/widen, and confirm the explicit preference.
6. Search a nested section, choose a lesson, and verify compact navigation closes.
   Re-select the current lesson: dismiss navigation without restarting playback.
7. Scroll elsewhere while playing. Confirm auto-advance doesn't force scrolling;
   use the scope button to return to the active lesson.
8. Open a resource while playing; return using the player button in the header.
9. Check the redesigned OSC in wide and compact layouts: title/up-next header,
   edge-to-edge timeline, amber play control, playback-options popover, and
   transient seek/pause/speed feedback. Verify settings stay usable while the
   controls are visible and fade only after playback resumes.
10. Select a playback speed, pause/resume, and advance. Confirm the selection
    persists and the footer has no duplicate transport controls.
11. Disable auto-next, finish a lesson, replay with the playback controls, and
    manually advance. Confirm completion is recorded and the last lesson has a
    disabled Next button.
12. Check light/dark appearance, keyboard navigation, and VoiceOver. Hidden
    course navigation must not retain interactive controls in the tab order.

13. Hover across the timeline, then drag rapidly forwards/backwards. Previews
    must follow the target without moving the playback clock until release.
    Keep the pointer still over the slider for more than three seconds: controls
    and preview must remain visible. Verify endpoint alignment and a bubble that
    stays within the controls at compact and wide widths.
14. Leave the timeline or switch lessons while a preview is loading. No old
    thumbnail may appear in the new lesson. Revisit a cached position, test a
    remote HTTP lesson, and check the loading/error states for unsupported media.
15. Tab to the seek slider and use arrow keys or VoiceOver adjustments; playback
    must seek immediately without requiring a mouse release.
16. Open the Library at wide, standard, and 480 × 360 pt sizes. Confirm the
    hierarchy remains search, Continue Watching when available, then All Courses,
    without clipped connection controls or unusable cards.
17. Search globally for a course, lesson, section, and resource. Verify grouped
    results, breadcrumbs, direct navigation/playback, Return-to-open, Escape to
    clear, and the labeled course-title fallback when the endpoint is unavailable.
18. Resume a Continue Watching entry and verify it opens the owning course and
    seeks to the persisted position. Complete it and confirm the card disappears
    without blocking the rest of the Library.
19. Check course, search, and recent cards with available, missing, and failed
    thumbnails. Generated covers/type icons must remain visible as fallbacks, and
    switching server origins must not briefly show images from the prior server.
20. Verify every course card shows its own progress summary. Routine playback
    updates must not reopen completed lessons; natural completion must remain
    sticky after leaving and reopening the course.

Physical display transitions and live libmpv rendering require manual validation;
unit tests do not substitute for those checks.
