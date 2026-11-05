# Adaptive playback workspace

The native macOS course workspace adapts to **window space in logical points**,
not display resolution. The app supports windows down to 480 × 360 pt.

## Layout

- **Wide (1,200+ pt):** resizable 300–480 pt course sidebar and playback.
- **Standard (850–1,200 pt):** sidebar clamped to leave a usable player pane.
- **Compact (under 850 pt):** playback-first, with temporary course navigation.
  Navigation is a drawer at 600+ pt and a full-width content view below 600 pt.
- Threshold hysteresis prevents repeated transitions during live resizing.
- Short windows (under 540 pt tall) omit the resume card and secondary player
  metadata; typography stays readable and primary controls remain available.
- AVKit aspect-fit rendering preserves the video, including instructional text.

The outline and playback inspector retain their SwiftUI identity across layout
changes. `LibraryModel` continues to own the AVPlayer. Progress reporting belongs
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
- AVKit alone provides play/pause, replay/seeking, volume, fullscreen, speed,
  audio, and subtitle selection. The footer adds only previous/next **lesson**
  navigation and an auto-next switch. No second media-control bar.
- The Continue/Resume card appears only before a playback session is active.
- With auto-play disabled, natural EOF shows completion; replay remains in AVKit.

## Verification

Automated: `make macos-test` covers layout thresholds/hysteresis, sidebar clamping,
lesson search ancestry/order, and playback speed bounds/persistence. Build the
native application with `make macos-build`.

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
9. Select 1.25× in AVKit's native speed controls, pause/resume, and advance.
   Confirm the native speed selection persists; no duplicate footer menu appears.
10. Disable auto-next, finish a lesson, replay using AVKit, and manually advance.
    Confirm completion is recorded and the last lesson has a disabled Next button.
11. Check light/dark appearance, keyboard navigation, and VoiceOver. Hidden
    course navigation must not retain interactive controls in the tab order.

Physical display transitions and live AVKit rendering require manual validation;
unit tests do not substitute for those checks.
