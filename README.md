<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Puffer's app icon: a smiling orange pufferfish on a teal rounded square">
</p>

<h1 align="center">Puffer</h1>

<p align="center">
  <a href="https://github.com/YucaApp/puffer/actions/workflows/ci.yml"><img src="https://github.com/YucaApp/puffer/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

Text expansion for the Mac. Type a shortcode such as `;sig` in any app and
Puffer replaces it with the text you saved for it: a signature, an address, a
reply you send every week.

![Puffer's editor window: folders on the left, the entries in the selected folder in the middle, and the selected entry's title, shortcode, trigger and text on the right](docs/screenshot.png)

- **Lives in the menu bar** and works in every app.
- **Folders and search.** Entries are organised into folders; the search
  field (Command-F) looks through every folder by title, shortcode and text.
- **Three ways to fire.** Each entry expands on a space, on a period, or the
  moment its last character is typed.
- **Undo with delete.** Pressing delete straight after an expansion puts the
  shortcode back (for expansions of up to 300 characters).
- **One plain file.** The library is a single JSON file that you can keep in
  a synced folder to share between Macs.
- **Small and private.** Native Swift, no dependencies, no network
  connections. It has to read your typing to do its job, so
  [Privacy](#privacy) says exactly what it does with it.

## Install

Puffer needs macOS 14 or later and runs on both Apple silicon and Intel Macs.

### Download

1. Download `Puffer-x.y.z.dmg` from the
   [latest release](https://github.com/YucaApp/puffer/releases/latest).
2. Open it and drag Puffer into Applications.
3. Open Puffer from Applications. Releases are not yet notarised by Apple, so
   the first time macOS will say it cannot check the app and refuse to open
   it. Go to **System Settings > Privacy & Security**, scroll down to the
   message about Puffer, and click **Open Anyway**.
4. Puffer asks for the Accessibility permission, which it needs to see
   shortcodes being typed and to replace them, and then whether to open at
   login.

Two things follow from the releases not being notarised:

- macOS ties the Accessibility permission to the exact build. After
  installing an update, remove Puffer from **Privacy & Security >
  Accessibility** and let it ask again.
- Nobody but the release workflow in this repository has vouched for the
  download. You can check it against the `.sha256` file published beside it
  (`shasum -a 256 -c Puffer-x.y.z.dmg.sha256`), and since this is an app that
  reads your typing, you may prefer to build it yourself.

### Build from source

This takes about a minute and needs only the Xcode Command Line Tools
(`xcode-select --install`; full Xcode is not needed).

```sh
git clone https://github.com/YucaApp/puffer.git
cd puffer
./scripts/make-signing-cert.sh   # once per Mac
./scripts/install.sh             # builds, installs to /Applications, launches
```

`make-signing-cert.sh` creates a certificate that is for building on your own
Mac only. Read [Signing](#signing) before running it. A copy you build this
way keeps its Accessibility permission across rebuilds.

Puffer is distributed outside the Mac App Store because sandboxed apps cannot
have the Accessibility permission.

## Using Puffer

Choose **Open Puffer…** from the menu bar icon, add an entry, and give it a
shortcode and some text. Starting shortcodes with a character you rarely type
on its own, such as `;`, keeps them from firing by accident.

Each entry chooses what fires it:

- **Space** or **Period**: type the shortcode, then that key. The space can be
  kept after the expanded text or dropped; the period is always dropped.
- **Immediately**: expands the moment the shortcode's last character is typed.

A shortcode that starts with a letter or digit only fires at the start of a
word, so `sig` does not fire inside `design`.

The menu bar icon is dimmed whenever expansion is not happening, and the menu
says why. **Pause Expansion** in the same menu switches it off for a while.

Don't want the icon? Choose **Hide Menu Bar Icon…**. Puffer keeps running.
To get back to it, open Puffer again from Applications or Spotlight: its
window's **Puffer** menu has the same settings and **Show Menu Bar Icon**.

## Privacy

Puffer has to see what you type in order to spot shortcodes, so here is
exactly what it does with that.

- **What it reads.** While it has the Accessibility permission, Puffer
  receives every key press on the Mac, in every app. It also notices mouse
  clicks, only to know that the insertion point may have moved. Choosing
  **Pause Expansion** switches this off completely: no key press reaches
  Puffer until you resume.
- **What it keeps.** At most the last 128 characters typed since the last
  click, arrow key, return, tab, keyboard shortcut or app switch, plus the
  shortcode of the last expansion so that delete can undo it. This is held
  in memory only, and is cleared after ten seconds without a key press.
- **What it stores or sends.** Nothing you type is written to disk or logged.
  Puffer makes no network connections at all.
- **Password fields.** macOS hides typing from Puffer in any field that turns
  on "secure input", which standard password fields and Terminal's Secure
  Keyboard Entry do, and Puffer also stops matching while secure input is on.
  A password box that does not turn on secure input (some web pages and
  cross-platform apps) looks like ordinary typing to Puffer, as it does to
  every other app with this permission.
- **The clipboard.** Expansions of up to 200 characters on a single line are
  typed and never touch the clipboard. A longer expansion, or one with line
  breaks or tabs, is put on the clipboard, pasted, and your previous
  clipboard is put back about half a second later. For those:
  - The expansion is marked so that clipboard managers skip it
    ([nspasteboard.org](http://nspasteboard.org) markers), but a clipboard
    manager that ignores those markers will record it.
  - If the clipboard holds a password copied from a password manager (marked
    "concealed"), Puffer does not copy it or put it back, because putting it
    back would stop the password manager clearing it later. A single-line
    expansion is typed instead, however long it is; after a multi-line one
    the clipboard is left empty. The same goes for a clipboard holding more
    than 5 MB, which is too slow to copy.
  - A password that its app did not mark as concealed is put back like
    anything else, as a new copy. A password manager that clears the
    clipboard only if it has not changed since will then not clear it.
- **The library file** is plain, unencrypted JSON. Do not put passwords or
  other secrets in expansions.

## Where the library lives

The library is one JSON file, `~/Library/Application Support/Puffer/library.json`.

To keep it somewhere else, for example in a folder that a sync tool shares
between your Macs, choose **Library Location > Choose Folder…** in Puffer's
menu. If the folder you pick already contains a library, Puffer switches to
it; otherwise it writes the current library there. Puffer re-reads the file
within a couple of seconds when something else changes it.

## How it works

- A `CGEventTap` feeds typed characters into a rolling buffer.
- When the buffer ends in a shortcode that should fire, Puffer swallows the
  key that fired it, sends backspaces over the shortcode, and inserts the
  expansion: typed if it is short and on one line, otherwise pasted, with the
  previous clipboard contents put back afterwards.
- Keys you press while that is happening are held and replayed straight
  after it, so fast typing stays in order.
- The buffer is cleared on mouse clicks, arrow keys, return, tab, keyboard
  shortcuts and app switches, and after ten seconds without typing (so a
  shortcode and its trigger key must be typed within ten seconds of each
  other, and delete only undoes an expansion for that long).
- Nothing expands while secure input is on (password fields), or while
  Puffer's own window is in front.
- A shortcode that starts with a letter or digit only fires at the start of a
  word, so `sig` does not fire inside `design`.
- Nothing expands while an input method (Japanese, Chinese, Korean and so
  on) is selected, because its key presses are not the text being written.
- The menu bar icon is dimmed whenever expansion is not happening, and the
  menu says why: paused, no Accessibility permission, another app holding
  secure input on, an input method selected, or Puffer's own window in front.
- Typed expansions arrive as key events that carry the text. An app that
  looks at which key was pressed rather than at the text (a remote desktop
  or virtual machine window, some games) will not receive them correctly.

## Development

`CLAUDE.md` describes the layout of the code. The logic that can be tested
without a keyboard (matching, undo, storage) lives in `Sources/PufferCore`.

```sh
./scripts/test.sh        # unit tests
./scripts/build-app.sh   # builds dist/Puffer.app without installing
./scripts/install.sh     # builds, installs to /Applications, relaunches
```

Changes to the event tap or the text injector need trying against real
typing in other apps; the unit tests cannot cover them.

### Signing

macOS ties the Accessibility permission to the app's code signature.
`make-signing-cert.sh` creates a self-signed certificate ("Puffer Local
Signing") in your login keychain so that every build is signed the same way
and the permission survives rebuilds. Without it builds are ad-hoc signed and
the permission must be re-granted after each one
(`tccutil reset Accessibility co.yuca.puffer`, then relaunch).

That certificate is for building on your own Mac only. So that builds do not
stop to ask for a password, its private key can be used by `codesign` without
a prompt. That means any program running as you could sign another binary as
"Puffer Local Signing" with Puffer's identifier, and macOS would give that
binary Puffer's Accessibility permission. That is an acceptable trade on a
development machine, where a program running as you can already do a great
deal, but it is the reason never to share a build signed this way, and to
remove the certificate if you stop building Puffer:

```sh
security delete-identity -c "Puffer Local Signing"
```

### Releases

Pushing a tag such as `v1.2.3` runs the release workflow, which builds
`Puffer-1.2.3.dmg` with `scripts/release.sh` and publishes it as a GitHub
release. The version number comes from the tag.

A release is never signed with the local certificate. Without further setup
it is ad-hoc signed, which is why the install steps above ask users to
approve it by hand. To publish releases that macOS opens without complaint,
add a Developer ID certificate and notarisation credentials as repository
secrets; `.github/workflows/release.yml` lists them. The same works locally:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=puffer ./scripts/release.sh 1.2.3
```

### App icon

`Resources/AppIcon.icns` is generated from `Resources/icon-source.png`, and
`docs/icon.png` (shown at the top of this file) is taken from it:

```sh
swift scripts/make-icon.swift
iconutil -c iconset -o /tmp/AppIcon.iconset Resources/AppIcon.icns
cp /tmp/AppIcon.iconset/icon_256x256@2x.png docs/icon.png
```

## Security

To report a security problem, see [SECURITY.md](SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).
