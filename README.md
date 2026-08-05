# Roost

[![ci](https://github.com/IKatsuba/roost/actions/workflows/ci.yml/badge.svg)](https://github.com/IKatsuba/roost/actions/workflows/ci.yml)

A native macOS workspace for [Claude Code](https://claude.com/claude-code)
sessions: projects, tabs, a tree of terminal panes, agent statuses and a command
palette.

Running several agents at once quickly turns into a bookkeeping problem — which
window asked a question, which one finished, which one is still thinking. Roost
answers that: every pane reports what its agent is doing, and the ones that need
a human come first.

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm);
everything else is written here.

## What it does

- **Projects and tabs.** A project is a directory; a tab is a session; a tab
  splits into a tree of panes, each holding `claude` or a plain shell.
- **Agent status without asking.** Claude Code's hooks report back: working,
  done, or waiting for you. Red means exactly one thing — nothing moves without
  a human.
- **An attention queue.** Every waiting agent in one list, longest wait first,
  with the question it is stuck on. Plus a feed of what happened today.
- **Sessions you can come back to.** Layout survives a restart, and a claude
  pane returns to its own conversation rather than a blank slate. Past sessions
  are searchable — including ones started in a git worktree.
- **Branches.** A pane can run its agent in a worktree of its own, created by
  Claude Code itself.
- **Notifications and a dock badge** when the window is not in front of you.
- **A command palette** (`⌘K`) over every pane, project, action and past
  session.

## Requirements

- macOS 14 or newer
- [Claude Code](https://claude.com/claude-code) installed and on your `PATH`
- Swift 6 toolchain (Xcode command line tools) to build

## Build and run

```sh
tool/bundle.sh        # -> build/Roost.app, ad-hoc signed
open build/Roost.app
```

**Run the `.app`, not the binary.** An executable started from a terminal
inherits your `PATH` and hides the trap: under launchd the app gets a bare
`/usr/bin:/bin`, where there is no `claude`. Notifications and the icon need a
bundle too.

To hand a build to another Mac:

```sh
tool/release.sh       # universal binary + build/Roost-<version>.zip
```

The signature is ad-hoc — there is no Developer ID and no notarisation, so on
the other machine Gatekeeper needs to be told once:

```sh
xattr -dr com.apple.quarantine /Applications/Roost.app
```

## Shortcuts

Hold `⌘` for a second to see the full list — it is generated from the menu, so
it cannot drift out of date.

| | |
|---|---|
| `⌘T` / `⌘⇧T` | new claude session / new shell |
| `⌘N` / `⌘⇧N` | new project / claude in a worktree |
| `⌘O` | open a past session |
| `⌘K` | command palette |
| `⌘D` / `⌘⇧D` | split right / down with claude |
| `⌘E` / `⌘⇧E` | split right / down with a shell |
| `⌘W` | close pane |
| `⌘⇧←→↑↓` | move between panes |
| `⌘1`…`⌘9` | switch session |
| `⌘⌥←→` / `⌘⌥1`…`⌘⌥9` | switch project |
| `⌘⇧A` | jump to an agent that is waiting |

## How it works

Claude Code does not publish its state, so Roost asks it the only way there is:
it raises a listener on the loopback, writes a small hook script next to its
snapshot and launches every agent pane with `--settings`. The hook stands in the
agent's way, so it is deliberately dumb — `grep` instead of `jq`, timeouts in
seconds, and `exit 0` whatever happens.

Sessions belong to the model rather than to the view: switching a tab must not
kill a PTY with everything running inside it. Roost also names each session
itself (`claude --session-id`), so a pane knows what to resume from its first
second, without waiting for a hook that may never arrive.

What it touches on your disk:

- writes `~/Library/Application Support/dev.katsuba.roost/` — the workspace
  snapshot and the generated hook files;
- reads `~/.claude/projects/**` — Claude Code's own transcripts, to list and
  name past sessions. Read-only, and never sent anywhere;
- listens on `127.0.0.1` on a port the OS picks, serving loopback connections
  only.

The intent and the history of decisions live in the doc comments on the types;
[CLAUDE.md](CLAUDE.md) is the map of the codebase.

## Development

```sh
swift build
swift test                                   # swift-testing, not XCTest
swift test --filter resumesKnownSession      # one test by function name
```

`RoostCore` holds all the logic with no AppKit import, which is why the tests
run in seconds without a screen; `Roost` is the SwiftUI/AppKit layer on top. If
a thing can be checked by a test, it belongs in `RoostCore`.

**Do not build in Xcode.** It compiles SwiftTerm's Metal shader and demands a
separate Metal Toolchain that `swift build` never asks for. Opening the package
as an editor is fine (`open Package.swift`); building is not.

The UI is checked by hand, on a bundled `.app`.

## Status

Young and used daily by its author. The parts that can be tested are tested; the
interface is not. Expect rough edges, and file an issue when you hit one.

## License

[MIT](LICENSE)
