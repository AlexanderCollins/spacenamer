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
- **Menu bar.** Shows the current Space's name (or number), changing the moment a switch
  starts, with a menu to rename it or jump to any other. With a menu bar on each display, each
  one names the Space on its own display.
- **Instant switching.** Jump straight to any desktop without the slide animation.
- **Switcher.** Press **⌃⌥Space** for a searchable list of your Spaces: type a few letters, press
  Return to go there, or rename from the list.
- **Shortcuts.** **⌃⌥1 … ⌃⌥0** for desktops 1–10, **⌃⌥Tab** to go back to the previous Space,
  and an optional shortcut of your own for any Space. All of them can be changed or turned off.
- **Name on switch.** A small pill at the top of the screen names the Space you're moving to,
  the moment the switch starts. It can be moved or turned off.
- **Scriptable.** A `spacenamer://` URL scheme for Shortcuts, Raycast, Alfred and shell scripts.
- **Coding agents.** Each Claude Code session (or any agent, through MCP) shows on the desktop
  its terminal is on: working, needs you, done or failed. Desktops take their chat's title as a
  name (and `/rename` renames the desktop), and new chats take their desktop's. See
  [Coding agents](#coding-agents).
- **Update notice.** When there are newer changes on GitHub, a small green arrow appears next to
  the name in the menu bar, and the menu lists what's new (each change opens on GitHub) with
  **Update SpaceNamer…** to pull and rebuild.

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

To update, run `git pull && make install` in the same folder, or choose **Update SpaceNamer…**
from the menu when it offers one: it runs the same two commands in Terminal.

If you use Claude Code, also install SpaceNamer's plugin (see [Coding agents](#coding-agents)):

```sh
claude plugin marketplace add AlexanderCollins/spacenamer
claude plugin install spacenamer@spacenamer
```

> **AI agents installing SpaceNamer for someone:** run the two `claude plugin` commands above
> as well when they use Claude Code, then tell them to run `/reload-plugins` in sessions that
> are already open.

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

Settings also has **Launch at login**, what the menu bar shows, where the switch pill appears,
and the switching method.

### Recommended macOS settings

- **System Settings → Desktop & Dock → Mission Control → "Automatically rearrange Spaces based
  on most recent use": off.** With it on, macOS reorders your desktops behind your back. Names
  still follow their desktops, but numbered shortcuts and positions keep changing.
- Shortcuts for "Switch to Desktop N" in **System Settings → Keyboard → Keyboard Shortcuts →
  Mission Control** are not needed: SpaceNamer has its own. They're used only if you choose the
  **Mission Control shortcuts** switching method (with the usual slide animation).

## Coding agents

SpaceNamer shows what each coding agent is doing on the desktop its terminal is on, so you can
leave agents working on several desktops and see at a glance which one wants you.

| State | Colour | When |
|---|---|---|
| Working | Blue, filling up with progress when the agent reports it | Since you sent a prompt |
| Needs you | Orange | Waiting for a permission, an answer to a question, or a plan to approve |
| Done | Green | Finished, and you haven't been back to that desktop since |
| Failed | Red | Stopped on an error, and you haven't been back since |

An idle agent (waiting for your next prompt, or a result you've seen) shows nothing. A desktop
shows its most urgent agent: in Mission Control its name turns that colour, in the menu and the
switcher it gets a coloured dot and a few words ("Needs you · Wants to use Bash"), and the menu
bar gets a dot whenever any desktop needs you, failed or finished. Done and failed clear once
you've been on that desktop for a moment.

**Names.** A desktop you haven't named takes its chat's title (Claude Code's own, or the one
you gave it), and follows it when it changes. Renaming a chat with `/rename` renames its desktop
straight away, even one you'd named; Claude Code's own titles never replace a name you gave a
desktop. A new chat on a desktop you named takes the desktop's name. Both directions can be
turned off in **Settings → Agents**.

**Which desktop.** In iTerm2 and Terminal, SpaceNamer asks the terminal which window shows each
agent's session, so an agent belongs to the desktop that window is on, and moves with it (macOS
asks you once to let SpaceNamer do this). In other terminals, it's the desktop the terminal was
on when you started the agent or last typed into it, until you move that window elsewhere.

### Claude Code

SpaceNamer follows every running Claude Code session on its own, from the status files Claude
Code keeps in `~/.claude/sessions`: working, waiting on you, finished, and the chat's name,
including sessions started before SpaceNamer. The plugin adds what those files don't say: a
turn that failed, progress through long tasks, and naming a new chat after its desktop.

Install the plugin (or use **Settings → Agents → Install…**, which runs the same commands):

```sh
claude plugin marketplace add AlexanderCollins/spacenamer
claude plugin install spacenamer@spacenamer
```

New sessions pick it up straight away; sessions already running after `/reload-plugins`. Its
hooks report each state as it happens (they run in the background and never hold Claude Code
up), and its MCP server gives Claude `set_status` for progress through long tasks, plus
`name_desktop` and `get_desktop`. To remove it: `claude plugin uninstall spacenamer@spacenamer`.

### Other agents and scripts

Any agent that speaks MCP can run SpaceNamer's server over stdio:

```sh
/Applications/SpaceNamer.app/Contents/Helpers/spacenamer mcp
```

Without hooks, states change only when the agent calls `set_status`. Scripts can use the same
helper directly:

```sh
spacenamer status working --progress 0.5 --note "Tests 3/5"   # or needs_input, done, failed, idle
spacenamer name "Release"                                       # name this terminal's desktop
spacenamer desktop                                              # which desktop is this?
```

(`spacenamer` is `SpaceNamer.app/Contents/Helpers/spacenamer`; link it into your `PATH` if you
use it often.)

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

SpaceNamer collects nothing. Its only network connection is the update check: every few hours
it asks GitHub's public API which commits on `main` are newer than the one your copy was built
from. That request carries nothing but the commit, and you can turn it off in
**Settings → General → Updates**. Agents talk to SpaceNamer through a socket only your user
account can open (`~/Library/Application Support/SpaceNamer/agent.sock`). It reads Claude
Code's session status files, and the end of a session's transcript only to find the chat's
title, and asks iTerm2 or Terminal which window shows which terminal. Names and settings are
stored locally in `~/Library/Preferences/com.alexandercollins.SpaceNamer.plist`. It does not
record your screen or your keystrokes.

## Uninstall

```sh
make uninstall
defaults delete com.alexandercollins.SpaceNamer   # optional: removes names and settings
```

Then remove SpaceNamer from **System Settings → Privacy & Security → Accessibility**, and, if
you installed the Claude Code plugin, run `claude plugin uninstall spacenamer@spacenamer`.

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
swift scripts/make-icon.swift   # redraws Resources/AppIcon.icns
```

The code is split into `Sources/CGSBridge` (the small C layer that talks to the window server),
`Sources/SpaceNamerCore` (the Spaces model, names, parsing, switching logic and the agent
protocol, all unit-tested), `Sources/SpaceNamer` (the app: menu bar, switcher, settings, the
switch pill, the Mission Control names and agent tracking) and `Sources/SpaceNamerAgent` (the
`spacenamer` helper: hooks, MCP server, scripts). The Claude Code plugin is in `claude-plugin/`;
try changes to it with `claude --plugin-dir claude-plugin`.

## Disclaimer

SpaceNamer is an independent project. It is not affiliated with, endorsed by or supported by
Apple Inc. macOS, Mission Control and Spaces are trademarks of Apple Inc.

It relies on undocumented macOS behaviour: private, read-only window server functions, the
private AppKit hooks that draw a menu bar item on other displays, the Dock's gesture events, the
layout of Mission Control's interface and the format of Claude Code's transcripts (for chat
titles). Apple doesn't support these and can change them in
any macOS update, which could break some or all of SpaceNamer until it is updated. It does not
disable or work around any macOS security protection.

The software is provided "as is", without warranty of any kind, express or implied. Use it at
your own risk; the authors are not liable for any damage or data loss arising from its use.
