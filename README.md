# SpaceNamer

Name your macOS Spaces and move between them instantly.

macOS calls every desktop "Desktop 1", "Desktop 2", … and renumbers them whenever you add,
remove or reorder one. SpaceNamer lets you give each desktop a real name that stays with it,
shows that name wherever you look for it, and switches desktops without the slide animation.

It runs as a small menu bar app on macOS 13 Ventura and later (Apple silicon and Intel). It
needs Accessibility access, and nothing more: **System Integrity Protection stays on**, nothing
is injected into other apps, and no system files are modified.

## Features

- **Names that stick.** Each name is tied to the Space itself, not its position, so it follows
  the desktop when you reorder desktops in Mission Control, and is forgotten only when that
  desktop is closed.
- **Names in Mission Control.** The names appear in Mission Control's Spaces bar in place of
  "Desktop N", and move with the bar as it opens, closes, expands into previews and rearranges.
- **Menu bar.** Shows the current Space's name (or number), with a menu to rename it or jump
  to any other.
- **Instant switching.** Jump straight to any desktop without the slide animation.
- **Switcher.** Press **⌃⌥Space** for a searchable list of your Spaces: type a few letters, press
  Return to go there, or rename from the list.
- **Shortcuts.** **⌃⌥1 … ⌃⌥0** for desktops 1–10, **⌃⌥Tab** to go back to the previous Space,
  and an optional shortcut of your own for any Space. All of them can be changed or turned off.
- **Name on switch.** A small pill at the top of the screen names the Space you're moving to,
  the moment the switch starts. It can be moved or turned off.
- **Scriptable.** A `spacenamer://` URL scheme for Shortcuts, Raycast, Alfred and shell scripts.

## Install

You need the Xcode Command Line Tools (`xcode-select --install`) or Xcode, with Swift 5.9 or
later.

```sh
git clone https://github.com/AlexanderCollins/spacenamer.git
cd spacenamer
make signing   # once: creates a local signing identity (see below)
make install   # builds a universal app, copies it to /Applications and opens it
```

`make app` builds `build/SpaceNamer.app` without installing it, and `make run` builds and opens
it from there. To install somewhere else: `make install INSTALL_DIR=~/Applications`.

### Why `make signing`?

macOS remembers the Accessibility permission per app *signature*. An unsigned or ad-hoc signed
app gets a new signature on every build, so you would have to grant the permission again after
each rebuild. `make signing` creates a self-signed certificate in a keychain inside this folder
(`.signing/`, never committed). It stays on your Mac and is trusted for nothing except
signing this app. Skip it and the app is ad-hoc signed instead, which works the same apart from
that.

You can also sign with your own identity: `SIGN_IDENTITY="Developer ID Application: …" make app`.

## First launch

1. SpaceNamer asks for **Accessibility** access. Turn it on in
   **System Settings → Privacy & Security → Accessibility**.
2. SpaceNamer restarts itself once access is granted (macOS applies the permission only to new
   launches).
3. Rename a Space from the menu bar, the switcher (⌃⌥Space), or **Settings → Spaces**.

Settings also has **Open at Login**, the menu bar style, where the switch pill appears, and the
switching method.

### Recommended macOS settings

- **System Settings → Desktop & Dock → Mission Control → "Automatically rearrange Spaces based
  on most recent use": off.** With it on, macOS reorders your desktops behind your back. Names
  still follow their desktops, but numbered shortcuts and positions keep changing.
- Shortcuts for "Switch to Desktop N" in **System Settings → Keyboard → Keyboard Shortcuts →
  Mission Control** are not needed: SpaceNamer has its own. They're used only if you choose the
  **Mission Control shortcuts** switching method (with the usual slide animation).

## URL scheme

```sh
open "spacenamer://go/3"              # desktop 3
open "spacenamer://go?name=Mail"      # the Space named Mail (best match)
open "spacenamer://next"              # next / previous Space
open "spacenamer://previous"
open "spacenamer://back"              # the Space you were on before
open "spacenamer://switcher"          # show the switcher
open "spacenamer://rename?name=Inbox" # rename the current Space
open "spacenamer://settings"
```

## How it works

- **Reading Spaces.** SpaceNamer asks the window server for the current layout of Spaces (the
  same information Mission Control uses). It only reads it, and polls cheaply while running.
- **Switching.** To move to a desktop, SpaceNamer posts the same swipe events a trackpad sends
  to the Dock, telling it to skip the animation, and checks that it arrived. If that ever stops
  working it falls back to the Mission Control keyboard shortcuts.
- **Mission Control names.** macOS doesn't let apps rename desktops, so SpaceNamer draws the
  names itself, in a click-through layer exactly over the Dock's labels. It finds the labels
  through Accessibility and mirrors the Dock's own animations as it opens, closes and expands.
- **Input.** To notice switches and Mission Control as they start, SpaceNamer listens (without
  changing or blocking anything) for shortcut presses and trackpad gestures. Ordinary typing,
  meaning keys without ⌃ ⌥ ⇧ ⌘, is ignored the moment it arrives, and nothing is recorded.

## Privacy

SpaceNamer makes no network connections and collects nothing. Names and settings are stored
locally in `~/Library/Preferences/com.alexandercollins.SpaceNamer.plist`. It does not record
your screen or your keystrokes.

## Uninstall

```sh
make uninstall
defaults delete com.alexandercollins.SpaceNamer   # optional: removes names and settings
```

Then remove SpaceNamer from **System Settings → Privacy & Security → Accessibility**.

## Known limitations

- The Mission Control names are drawn over the Dock's own labels rather than replacing them.
  They track the Dock closely, but in some very fast gestures the two can be a frame apart.
- Built and tested on a single display. Multiple displays, with or without "Displays have
  separate Spaces", should work but have had less testing.
- Full-screen app Spaces can be switched to and are shown by app name; showing their names in
  Mission Control has had less testing than desktops.
- macOS updates can change any of the behaviour SpaceNamer relies on (see below).

## Development

```sh
make debug   # debug build for this Mac's architecture
make test    # unit tests (swift-testing; works with the Command Line Tools alone)
make clean
```

The code is split into `Sources/CGSBridge` (the small C layer that talks to the window server),
`Sources/SpaceNamerCore` (the Spaces model, names, parsing and switching logic, all
unit-tested) and `Sources/SpaceNamer` (the app: menu bar, switcher, settings, the switch pill
and the Mission Control names).

## Disclaimer

SpaceNamer is an independent project. It is not affiliated with, endorsed by or supported by
Apple Inc. macOS, Mission Control and Spaces are trademarks of Apple Inc.

It relies on undocumented macOS behaviour: private, read-only window server functions, the
Dock's gesture events and the layout of Mission Control's interface. Apple doesn't support
these and can change them in any macOS update, which could break some or all of SpaceNamer
until it is updated. It does not disable or work around any macOS security protection.

The software is provided "as is", without warranty of any kind, express or implied. Use it at
your own risk; the authors are not liable for any damage or data loss arising from its use.
