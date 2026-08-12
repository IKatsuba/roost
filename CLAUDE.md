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

### What it costs

Two halves from two places, and neither is optional. Anthropic reports
**percentages** and no tokens; the transcripts hold **tokens** and no ceiling.
Neither number answers "how much is left, and what did it go on" alone.

The tokens are counted out of the same `~/.claude/projects` files
`SessionCatalog` reads for names: every reply carries a `usage` block. Three
things about that are worth knowing before touching `UsageScan`.

**Nearly half of the replies are written twice.** In this repository's own
transcripts, 1877 of 4227 were duplicates — byte-identical copies of a reply
already recorded, always within the same file. Counting them as they come puts
the bill at almost double. They are recognised by `messageId:requestId` and
merged field by field rather than skipped: a streamed copy carries the counters
as they stood when it was written, so the largest of each field is the true one.

**A session is not one file.** Every subagent gets a transcript of its own under
`<uuid>/subagents/`, and that is where parallel work goes — walking only the top
level lost 17% of the tokens and 29% of the money here. They count against the
session that spawned them: for a human that is one piece of work. `journal.jsonl`
sits among them and looks the same, but it is the orchestration log and has no
usage in it.

**The scan is written over raw bytes on purpose.** 1.3 GB of transcripts, single
lines up to 1.6 MB. `Data.split` plus `contains` took 178 seconds; `memchr` for
the line breaks and `memmem` for the one substring that matters took 12, over
four times the files. The first pass is the expensive one — after it each file
is re-read from the offset it stopped at, and catching up costs a fifth of a
second.

**The count is kept in `usage.json`**, beside the workspace snapshot: per-file
offsets, the totals, and the records of the last week. Without it every launch
re-read the gigabyte — with it a launch is 0.04 s instead of 12. Only offsets
are saved, never the dedup keys: those recognise a duplicate on a second pass
over the same bytes, and those bytes are never read again. Records are written
without their keys too, as `[time, model, …five counts]` rows — a third of the
file for an answer nobody asks twice. The file is a cache and nothing else: a
version bump, a truncated write or a missing file all mean the same thing, one
slow launch, which is why quitting does not block to write it.

Money is a **list price, not a bill**: a subscription pays nothing per token.
It is shown anyway because it is the only thing that puts a cache read and an
output token on one scale. The rates are per family (`opus`, `sonnet`, `haiku`,
`fable`) rather than per model id, matched by substring — ids turn over every
few months, and a table keyed by the exact one would answer "free" for a model
it had never heard of. Cache is priced by multiplier: ×1.25 for a five-minute
write, ×2 for an hour's, ×0.1 for a read.

The ceilings come from `api.anthropic.com/api/oauth/usage` with the token Claude
Code already has — the same request its own `/usage` makes. Two decisions there:

The keychain is read by running **`/usr/bin/security`**, not through
`SecItemCopyMatching`. The entry was written by Claude Code, so its access list
names Claude Code; anybody else asking directly gets the "wants to use your
confidential information" dialog. Asked through `security`, the permission a
human grants once belongs to `security` — which every other tool on the machine
already goes through.

**The token is used and never refreshed**, which is the one thing the tools that
do this get wrong. The refresh token is rotated on use: spend it and the copy in
the keychain is dead, so a bug in the write-back logs a human out of the very
agent this app exists to run. An expired token is reported as expired, and the
next read finds the one Claude Code has already put there — it is refreshing it
anyway, in the pane next door.

Three places show it, because it answers three different questions. **How much
is left** is the status bar: both windows, percentage and reset, muted — and the
window past four fifths set in full text colour, the same trick the count of
waiting agents uses instead of a hue. It is deliberately not in the window bar,
which holds only the path and the view switch: a percentage that is always on
screen is news about one afternoon in ten. **What this session came to** is the
card in the overview, on its bottom line, next to the model that explains why
two sessions of the same length cost differently. **Where it all went** is the
`SPEND` view of the right-hand strip, beside the queue and the feed: the windows
with what they cost, the current session split by model, the open sessions
dearest first, then the projects. The strip's footer carries the caveat the
numbers owe — *list price, not a bill*.

The five-hour window's boundaries are taken from the API's `resets_at` when
there is one, and the tokens are summed inside them. That is the only way the
two halves agree: a window opens at the first request after the last one closed,
which is not the same as five hours ago.

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

Cutting one, in full:

```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2.3' \
                        -c 'Set :CFBundleVersion 6' tool/Info.plist
git commit -am 'chore: 0.2.3'
git push origin main
git tag v0.2.3 && git push origin v0.2.3
```

The rest happens on its own: `.github/workflows/release.yml` refuses to build
unless the tag agrees with `CFBundleShortVersionString`, then signs, notarises,
staples, and leaves the `.zip` on a **draft** release. Write the notes, publish,
and `cask.yml` bumps the tap. Nothing else is done by hand — least of all the
cask.

Two things it needs. The secrets on the repository — `CERTIFICATE` (base64
`.p12`), `CERTIFICATE_PASSWORD`, `NOTARY_KEY` (base64 `.p8`), `NOTARY_KEY_ID`,
`NOTARY_ISSUER`, and `TAP_TOKEN` (a fine-grained PAT with contents:write on the
tap, since `github.token` does not reach past this repository). And patience:
notarisation is Apple's queue, anywhere from a minute to half an hour, which is
normal rather than a hang — `xcrun notarytool history --keychain-profile
roost-notary` answers independently of whatever is waiting on it.

`tool/release.sh` does the same thing locally when CI is not an option; it wants
the certificate and the `roost-notary` profile in the keychain.
`ROOST_SKIP_NOTARIZE=1` stops after the signature, and
`gh workflow run release.yml -f dry_run=true` does the same on a runner —
worth knowing, because the fragile half of that job is the keychain, not Apple,
and a dry run answers in two minutes what a full one takes an hour to say.

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
