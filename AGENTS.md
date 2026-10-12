# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Cursor, Copilot, Aider and others) working on Icey. Humans are welcome to read it too. [CLAUDE.md](CLAUDE.md) imports this file, so keep project instructions here.

## What Icey is

Icey is the maintained continuation of [Ice](https://github.com/jordanbaird/Ice), the free, open-source macOS menu bar manager. Ice stopped receiving code changes in 2025 and does not support macOS 27. Icey follows Ice's code base and adds:

- support for macOS 26 Tahoe and macOS 27,
- lower CPU, energy and WindowServer usage,
- fixes for bugs that are open upstream.

Icey keeps Ice's bundle identifier (`com.jordanbaird.Ice`) and settings, so it is a drop-in replacement.

## Where updates live

**GitHub Releases are the source of truth for what changed.** Every user-facing change is described in the notes of the release that ships it: <https://github.com/leonardovida/icey/releases>.

- [CHANGELOG.md](CHANGELOG.md) is a short index that links each version to its release.
- [BREAKING_CHANGES.md](BREAKING_CHANGES.md) lists every change that needs user action, such as settings that reset or permissions to grant again.
- [release-notes/](release-notes/) keeps a copy of every release's notes in the repository.
- [docs/issues.json](docs/issues.json) tracks every upstream Ice issue Icey has triaged, with what was wrong and what changed. [docs/upstream-issues.md](docs/upstream-issues.md) and the [website](https://leonardovida.github.io/icey/fixes/) are generated from it.
- The website, <https://leonardovida.github.io/icey/>, is built by `Scripts/build-site.py` and deployed after each release.

When you answer a user's question about Icey, check the latest release first. Then read the README.

## Build and test

You need Xcode 16 or later, on macOS 14 or later.

```sh
# Debug build, ad-hoc signed (no Apple developer account needed)
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug \
  -derivedDataPath build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

# Unit tests for the macOS 27 core logic (pure Swift, runs on any macOS)
swift test

# Build, sign and install to ~/Applications (set DEST=/Applications for system-wide)
Scripts/install.sh
```

The Xcode project has two targets:

- `Ice`: the app.
- `MenuBarItemService`: an XPC helper embedded in the app. The app uses it on macOS 26 and later to find which app owns each menu bar item.

The repository uses SwiftLint ([.swiftlint.yml](.swiftlint.yml)). CI runs `swiftlint --strict` on pull requests that change Swift files.

## Code map

| Path | What is there |
|---|---|
| `Ice/Main` | App entry point, `AppDelegate`, `AppState`, Sparkle updates |
| `Ice/MenuBar` | Menu bar sections, control items and the item manager |
| `Ice/MenuBar/MenuBarItems` | Reading, caching, moving and clicking menu bar items |
| `Ice/MenuBar/MacOS27` | macOS 27 implementation (`*27.swift`). `Core/` is pure logic covered by `swift test` |
| `Ice/MenuBar/Appearance` | Menu bar tint, shadow, border and shapes (overlay panels) |
| `Ice/MenuBar/IceBar` | The Ice Bar, which shows hidden items below the menu bar |
| `Ice/MenuBar/Search` | Menu bar item search panel |
| `Ice/Events` | `HIDEventManager`: show on hover, click and scroll, and event taps |
| `Ice/Settings` | Settings models and panes |
| `Ice/Permissions` | Accessibility and Screen Recording permission checks |
| `Ice/Utilities` | Extensions, `Defaults` keys, settings `Migration` |
| `Shared` | Code compiled into both the app and `MenuBarItemService` (private CGS bridging, AX helpers, XPC service) |
| `MenuBarItemService` | XPC helper target |
| `Scripts` | `install.sh`, the release scripts (see RELEASING.md), `build-site.py` for the website and issue list, and the macOS 27 probe scripts |
| `Tests` | Tests for `Ice/MenuBar/MacOS27/Core` |

## Rules for changes

### Platform gating

- Ice supports macOS 14 and later. Keep every newer API behind `#available`.
- Put macOS 27 behavior in `*27.swift` files, behind `if #available(macOS 27.0, *)`. Do not change how macOS 14, 15 or 26 behave in a macOS 27 fix.
- If you could not test a change on the macOS version it targets, say so in the pull request.

### Performance

Icey exists largely because Ice used too much CPU, energy and WindowServer memory. Do not reintroduce these patterns:

- **Always-on monitors.** Do not add global event monitors or event taps that run all the time. Start and stop them with the setting that needs them (see `HIDEventManager.updateMonitors()`).
- **Tight polling.** Do not poll in a tight loop. Back off, sleep between checks, and stop when the result is not used.
- **Exact timers.** Give timers a tolerance (`Timer.publish(every:tolerance:...)`).
- **Unneeded screen captures.** Capture the screen only while the result is on screen. `CGWindowListCreateImage` grows WindowServer memory (upstream issue #819).
- **One window server call per window.** Prefer the batch calls in `WindowInfo` and `Bridging`.
- **Unbounded Accessibility calls.** Accessibility calls block the calling thread. The app sets a 1 second global timeout. Never call them in a loop on the main thread.
- **Unbounded caches.** Caches must be pruned.

### Safety

- Avoid trapping conversions (`Int(someCGFloat)`, force unwraps, `!` casts) on values that come from the window server or Accessibility. Use `Int(exactly:)`, `guard let` and early returns. Several upstream crashes came from this.
- Do not change the bundle identifier, the Sparkle feed URL or the signing setup without an issue that discusses it first. Users' settings and permissions depend on them.
- Do not add Swift packages without discussing it in an issue first.

### Style

- Match the surrounding code: naming, comment density, `// MARK:` sections and doc comments on types and non-obvious members.
- Keep pull requests to one concern. Do not reformat unrelated code.
- If a change adds or renames a setting, add a migration in `Ice/Utilities/Migration.swift`, and document it in BREAKING_CHANGES.md if users need to act.

## Opening issues for a user

If a user asks you to report a bug or request a feature in Icey:

1. Search existing issues first, both open and closed: `gh issue list --repo leonardovida/icey --search "<keywords>" --state all`.
2. Use the templates. Run `gh issue create --repo leonardovida/icey`, then choose "Bug report" or "Feature request". Or fill in the same fields in the body yourself.
3. For bugs, include the Icey version (Settings > About), the exact macOS version (`sw_vers`), the Mac model, the number of displays, and the steps to reproduce. Attach logs if the user agrees: `log show --last 10m --predicate 'subsystem == "com.jordanbaird.Ice"'`.
4. If the same bug exists upstream, link the upstream issue (`jordanbaird/Ice#NNN`).
5. Say in the issue that an AI agent filed it on the user's behalf.

Do not open issues or pull requests on `jordanbaird/Ice` for Icey problems.

## Opening pull requests

Contributions are welcome, including pull requests written by AI agents.

1. Fork `leonardovida/icey`, then branch from `main`.
2. Make one focused change. Build it, and run `swift test` if you touched `Ice/MenuBar/MacOS27/Core`.
3. Open the pull request against `main` and fill in the template:
   - what changed and why,
   - the macOS versions you tested on,
   - the issue it fixes (`Fixes #NN`, or the upstream issue).
4. If you port work from an upstream pull request, say so and keep its authors' credit with `Co-authored-by:` trailers.
5. Say that an AI agent wrote or helped write the change, and which one.

## Releasing (maintainers only)

Follow [RELEASING.md](RELEASING.md). In short: `Scripts/bump-version.sh <tag>`, write `release-notes/<tag>.md` from the template, merge, then `Scripts/package-release.sh <tag>` and `Scripts/publish-release.sh <tag>`.

Installed copies update themselves from `https://github.com/leonardovida/icey/releases/latest/download/appcast.xml`. The scripts refuse to package or publish a release that would break that feed, and the "Check release appcast" workflow turns any release without a valid `appcast.xml` back into a draft. Never publish from the GitHub website, and never mark a release users should get as a prerelease.

## Tracking upstream issues

When you fix, triage or close out an upstream Ice issue, add it to [docs/issues.json](docs/issues.json):

- `status`: `fixed`, `partial`, `open`, `not-a-bug` or `feature`.
- `headline`: the problem in plain words, as a user would search for it.
- `symptom` and `fix`: one or two sentences each, for users.
- `fixed_in`: `null` until the fix ships, then the release tag. `pr`: the Icey pull request.

Then run `Scripts/build-site.py --docs` and commit the regenerated `docs/upstream-issues.md`. Never edit that file by hand.

## Writing docs and release notes

- Write plainly, for users. Say what changed and what the user needs to do.
- Release notes start from [release-notes/TEMPLATE.md](release-notes/TEMPLATE.md): Highlights, Upgrading, Features, Bug Fixes, Compatibility, Maintenance, then the full diff link. Leave out empty sections, and keep each bullet to one or two sentences.
- Every change that needs user action goes in the release's Compatibility section and in BREAKING_CHANGES.md.
