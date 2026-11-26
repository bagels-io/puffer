# puffer

Text expansion app for the Mac. Native Swift, menu bar app. README.md says
what it does and how it works.

Scope is deliberately small: folders of entries, each with a title, a
shortcode, the text, and a trigger (space, period or immediate). Delete
straight after an expansion undoes it. No third-party dependencies.

## Layout

- `Sources/PufferCore` — pure logic, no AppKit: data model, JSON storage,
  shortcode matching and undo (`Matcher`). Unit tested.
- `Sources/Puffer` — the app: `ExpansionEngine` (CGEventTap), `TextInjector`
  (backspaces, then typed text or a clipboard paste), `AppDelegate` (menu bar
  item, windows, permission flow, login item), `LibraryModel` + SwiftUI editor.
- `Resources/Info.plist` — bundle metadata. Bundle id `co.yuca.puffer`.

## Commands

- `./scripts/test.sh` — unit tests (wraps `swift test`).
- `./scripts/install.sh` — build, install to /Applications, relaunch.
- `./scripts/build-app.sh` — build `dist/Puffer.app` only.
- `./scripts/make-signing-cert.sh` — once per Mac; see README.
- `./scripts/update-emoji.sh` — regenerate `EmojiData.swift` from the latest
  Unicode and CLDR data (needs the network; the app never does).
- `./scripts/release.sh [version]` — build the universal disk image for a
  release. Normally run by CI when a `v*` tag is pushed.

## Gotchas

- macOS only: it cannot be built or tested on Linux.
- Must build with only the Command Line Tools. Their SDK lacks the SwiftUI
  macro plugin, so `@State` and `#Preview` do not compile; keep view state on
  the `@Observable` model. (`@Bindable`, `@Binding`, `@FocusState` are fine.)
- The Accessibility grant is tied to the code signature. Local builds are
  signed with the self-signed "Puffer Local Signing" certificate so the grant
  survives rebuilds. If that certificate is missing the build falls back to
  ad-hoc and the grant is lost each time.
- Expansion is off while Puffer's own window is frontmost. Test in another app.
- Changes to the engine or injector need testing against real typing in
  other apps; the unit tests only cover `PufferCore`.
- The library is a JSON file that a sync tool may rewrite at any time.
  `LibraryModel` polls for that; never assume the in-memory library is the
  only writer. Edits made to the file by hand or by script are picked up
  within a couple of seconds.
