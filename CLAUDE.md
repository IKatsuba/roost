# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Roost is a native macOS workspace for Claude Code sessions: projects, tabs, a
tree of panes with terminals, agent statuses, a command palette. The terminal is
SwiftTerm, everything else is ours. There is no README in the repository; the
intent and the history of decisions live in the doc comments on the types.

## Commands

```sh
swift build                      # build
swift test                       # all tests (swift-testing, not XCTest)
swift test --filter resumesKnownSession   # a single test by function name
tool/bundle.sh                   # build/Roost.app, ad-hoc signature
tool/release.sh                  # universal, Developer ID, notarised -> .zip
swift tool/icon.swift tool/Roost.icns     # redraw the icon
```

**Xcode will not do for building.** It compiles SwiftTerm's Metal shader and
demands a separate Metal Toolchain, which `swift build` never asks for. Opening
the project as an editor is fine (`open Package.swift`), building is not. For
the same reason `swift build --arch arm64 --arch x86_64` does not work: `--arch`
switches SPM over to Xcode's build system. The universal binary in `release.sh`
is built in two `--triple` passes and glued with `lipo`.

**Check by hand only with the built `.app`.** An executable launched from a
terminal inherits your `PATH` and masks the main trap: under launchd the app
gets a bare `/usr/bin:/bin`, where there is no `claude`. Notifications and the
icon need a bundle too.

## How it is built

### Two targets

`RoostCore` is all the logic without a single AppKit import, which is why
`swift test` runs in seconds without a screen. `Roost` is SwiftUI/AppKit on top
of it. The rule is simple: if a thing can be checked by a test, it belongs in
`RoostCore`.

### WorkspaceModel is the single source of truth

A `@MainActor @Observable` class: projects, tabs, the pane tree, live sessions,
the event feed. Views are pure functions of it and hold almost no state of their
own (the exceptions are editing drafts and gestures such as dragging a divider,
which travel into the model on `.onEnded`).

### Sessions belong to the model, not to the view

`TerminalSession` owns `PaneTerminalView` (a subclass of
`LocalProcessTerminalView`). The SwiftUI wrapper `TerminalPaneView` returns an
**already existing** `NSView` and creates nothing. This is not a matter of
style: the moment a view starts owning the terminal, switching a tab kills the
PTY together with every running process. The same lesson was learned on a
Flutter prototype.

### The pane tree is immutable

`PaneNode` is an `indirect enum { leaf, split }`; `replacing`, `removing`,
`updating` and `settingRatio` return a new tree. `Codable` is written by hand
rather than synthesised for the enum: the snapshot has to stay readable and must
not drift when a case is renamed. Navigation via `neighbour(of:to:)` climbs from
the leaf to the nearest split on the right axis — `⌘⇧→` lands in the pane that
really borders on the right.

### The snapshot

`WorkspaceStore` writes
`~/Library/Application Support/dev.katsuba.roost/workspace.json` atomically. A
broken file does not stand in the way of launching — we start from a clean
state. Saving is deferred (`scheduleSave`, 400 ms), so there is no need to poke
`save()` by hand after changing the model. Only the structure is restored: the
PTY comes up anew, and a claude pane returns to its session through `--resume`.

### Claude Code hooks

Claude Code does not hand its state out, but it can call commands on events.
`AgentHooks` raises an `NWListener` on the loopback (the OS picks the port),
writes `hooks/notify.sh` and `hooks/claude-settings.json` next to the snapshot,
and the pane is launched with `--settings` and with `ROOST_PANE_ID` /
`ROOST_HOOK_URL` in its environment. The script serves `127.0.0.1` only and is
deliberately undemanding — `grep` instead of `jq`, timeouts in seconds, `exit 0`
whatever happens: **it stands in the agent's way**, and hanging here means
hanging the session.

The event table is `statusForEvent`. A subtlety of meaning: `Stop` is `done`
("the output is written, but nobody has read it"), not rest; it turns into
`idle` when a human opens the tab. A red `waiting` means exactly one thing:
nothing moves without a human.

### Launching a pane

`PaneLaunch` assembles `shell -l -i -c "…"`. `-i` is mandatory: `PATH` is edited
in `.zshrc`, which a non-interactive login shell does not read.

The pane is given somebody else's `TERM_PROGRAM` — `ghostty`. Without it
Shift+Enter does not work in the agent: in a plain terminal it is
indistinguishable from Enter (both are `\r`), the extended keyboard protocol is
what tells them apart, and Claude Code turns that protocol on by an allow-list
of terminal names, without asking about capabilities. SwiftTerm speaks the
protocol, "Roost" is not on the list. From a terminal the trap is invisible —
there the variable is inherited from the emulator; under launchd there is none,
same as `PATH`.

`CLAUDE_CODE_FORCE_SESSION_PERSISTENCE` is **deliberately not set** — with it, a
closed pane leaves the session living as a background agent under the daemon,
and `--resume` does not attach to such a session at all, so the human meets a
red line instead of an agent. Continuation has a safety net: if `--resume` fell
over in less than 5 seconds, the pane opens a clean session instead of a dead
screen.

### The session's name

Roost **assigns the session id itself** and puts it into the snapshot before the
pane even starts: `claude --session-id <uuid>`. Otherwise it would arrive only
with the first hook, and everything that loses a session fits between the launch
and the hook — a closed tab, broken settings, a crashed app.

One and the same session goes by two different flags, and they must not be
confused: claude greets a taken id with `Session ID … is already in use`, an
empty `--resume` has nothing to continue, and together they do not get along at
all (only with `--fork-session`). The fork is **the transcript on disk**, and
only it: the `transcriptPath` field of the snapshot is brought by a hook, so the
file is also looked up by id, in the directory of the cwd the session is kept in
(for a branch, its own). The safety net after a failed `--resume` carries no
session name: the id is taken by the very transcript that led us there.

The name of the transcript directory is built from the **resolved** path: the
pane's process sees its cwd without symlinks, and a session from `/tmp` lies in
`-private-tmp`.

### Branches

The worktree is created by Claude Code itself: `claude -w name` runs
`git worktree add` in `<project>/.claude/worktrees/<name>` on branch
`worktree-<name>`, and running it again with the same name enters the existing
one. Roost stores the **name**, not the path (`PaneSpec.worktree`), and the pane
still starts in the project directory — the agent takes it into the branch.

The flag is passed next to `--resume` as well: a branch's session lives in the
worktree directory, and without it there would be nothing to continue —
`--resume` looks only into its own cwd's catalog. For the same reason
`SessionCatalog` walks the branch directories on equal terms with the project's:
for a human this is one project, for Claude Code these are different cwds.

The name is sanitised twice — on input and at the command itself
(`Worktree.sanitize`). It travels into a shell string inside single quotes,
while the snapshot is ordinary json a quote can be typed into by hand.

### Looks

The app wears [katsuba.dev](https://katsuba.dev)'s design: the same neutral
scale, the same face, the same habit of separating things with a line instead of
a fill. The palette tokens are that site's oklch values converted to sRGB —
`#FFFFFF`/`#0A0A0A` for the ground, `#0A0A0A`/`#FAFAFA` for text, two greys
between, and a hairline that is white at a tenth in the dark.

**No colour at all — states are told apart by texture.** `AgentMark` draws the
square with a different fill per state: solid for waiting, bars for working (the
one thing allowed to move), a 4×4 checker for done, an outline for idle and
exited. Lightness carries the same order, so the ladder still reads where a mark
is too small for a pattern — the strips under a project's name, for one.

Texture beats hue for the same reason it does on a printed chart: it survives
greyscale, colour blindness, and a screenshot pasted into a chat. Where a mark
does not fit at all, the rank shows as weight instead: a count of waiting agents
is set in full text colour while everything around it is muted, and a project
whose directory has vanished is struck through rather than painted.

**Both themes, by system appearance.** The tokens are dynamic `NSColor`s, so
AppKit and SwiftUI resolve them per view and nothing has to be reloaded. The
terminal is the exception: SwiftTerm copies a colour the moment it is set, so
`PaneTerminalView.viewDidChangeEffectiveAppearance` re-applies the theme —
without it, switching macOS to light left a black pane inside a white window.

**Geist Mono travels in the bundle** (`Sources/Roost/Resources`, OFL licence
alongside) and is registered from `Bundle.module` on first use. The terminal
keeps Menlo on purpose: Geist Mono has box drawing and blocks but no braille,
and braille is what Claude Code spins while an agent works (`⠋⠙⠹`), along with
the `✳` in its own title. Missing glyphs come from a fallback face of another
width, and a terminal grid pays for that in drifting columns.

### Shortcuts

They are declared as `NSMenu` items in `AppDelegate`, not through SwiftUI
`Commands` and not by intercepting keys: that way a human can see them and they
do not argue with whatever is being typed in the terminal.

Only bare `⌘` combinations are reliable. Verified: the system takes `⌥⌘D` for
the Dock and `⌃⌘D` for "Look Up", and such a press never reaches the menu at
all, even though the item is registered correctly. The registration can be
checked without pressing anything, through Accessibility:

```sh
osascript -e 'tell application "System Events" to tell process "Roost"
return value of attribute "AXMenuItemCmdModifiers" of menu item 1 of menu 1 of menu bar item "Pane" of menu bar 1
end tell'
```

The `⌘K` palette lives in a separate `NSPanel` (`PaletteWindow`) rather than as
a layer inside the main window: inside the window the first responder is the
terminal, and taking that away for a text field would mean fighting SwiftTerm
over every keystroke.

### Releases

A release is cut by a tag: `v0.2.2` pushed to the repository runs
`.github/workflows/release.yml`, which refuses to build unless the tag agrees
with `CFBundleShortVersionString`, signs, notarises, and leaves the `.zip` on a
**draft** release for the notes to be written by hand.

The signature is the point of the whole path. An ad-hoc bundle is refused as
damaged on any machine but the one that built it, and Homebrew Cask puts the
quarantine attribute *on* what it installs, so `brew` and ad-hoc do not meet at
all. Hence `--options runtime` (notarisation rejects a submission without the
hardened runtime, which is why `bundle.sh` turns it on too — let it break in the
build run every day) and `--timestamp` (a signature without one stops verifying
the day the certificate expires, taking every copy already downloaded with it).

Apple returns the ticket separately from the submission, so the archive sent for
notarisation is a throwaway: the one people download is packed after `stapler`,
or every first launch would go asking Apple for a ticket the bundle does not
carry.

Locally the credentials live in the keychain — a certificate and a `notarytool`
profile named `roost-notary`. A runner has neither, so `release.sh` also takes
`ROOST_NOTARY_KEY` / `_KEY_ID` / `_ISSUER`. The one non-obvious step in the
workflow is `security set-key-partition-list`: without it a freshly imported key
asks for confirmation in a dialog nobody is there to answer, and `codesign`
looks hung rather than failed.

The cask lives in [IKatsuba/homebrew-tap](https://github.com/IKatsuba/homebrew-tap)
and is bumped by `cask.yml` — on publish rather than on the tag, since a draft's
asset is not downloadable and a cask pointing at one answers 404 to everybody
but its author. The tap is another repository, so that workflow needs a token of
its own: `github.token` does not reach past the repository it belongs to.

## Conventions

- **Comments, doc comments and test names are in English.** Interface text is
  lowercase English too (`no projects yet`, `⌘N PROJECT`).
- A comment explains **why**, not what the code does. Almost every one in this
  repository answers "why not the obvious way" — keep the bar there.
- Swift 6, strict concurrency. SwiftTerm's and UserNotifications' protocols are
  declared without `@MainActor`, so they are conformed to through
  `@preconcurrency`.
- Styling goes only through `Palette` / `Typography` / `Metrics` from
  `Theme.swift`. The interface has no rounded corners and no shadows; dividers
  are hairlines. See **Looks** below for what the palette is and why.
- Tests are written with swift-testing (`@Suite`, `@Test`, `#expect`), the UI is
  checked by hand.
