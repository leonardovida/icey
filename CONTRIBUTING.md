# Contributing to Icey

Thanks for helping keep Icey, the maintained continuation of Ice, working on current macOS. Bug reports, feature requests and pull requests are all welcome, from people and from AI agents.

## Report a bug

1. Check that you're on the [latest release](https://github.com/leonardovida/icey/releases/latest), and read [BREAKING_CHANGES.md](BREAKING_CHANGES.md) and [FREQUENT_ISSUES.md](FREQUENT_ISSUES.md).
2. Search [existing issues](https://github.com/leonardovida/icey/issues?q=is%3Aissue), open and closed.
3. [Open a bug report](https://github.com/leonardovida/icey/issues/new?template=bug_report.yml). Include:
   - your Icey version (Settings > About),
   - your exact macOS version,
   - your Mac model and number of displays,
   - steps to reproduce.

If the bug also exists in Ice, link the upstream issue. Please don't report Icey bugs on jordanbaird/Ice.

## Request a feature

[Open a feature request](https://github.com/leonardovida/icey/issues/new?template=feature_request.yml). Describe the problem it solves before the solution. The unchecked items in the [README feature list](README.md#features) are good candidates.

## Send a pull request

1. Fork the repository and branch from `main`.
2. Read [AGENTS.md](AGENTS.md): it has the build commands, a map of the code, and the rules every change follows (platform gating, performance and safety).
3. Keep the change focused on one fix or feature, in the style of the surrounding code.
4. Build it, and run `swift test` if you changed `Ice/MenuBar/MacOS27/Core`.
5. Open the pull request against `main` and fill in the template. Say which macOS versions you tested on.

Porting a fix from an open Ice pull request is welcome. Credit its author with a `Co-authored-by:` trailer.

## Using an AI agent

Agent-written issues and pull requests are welcome. Point your agent at the repository: Claude Code reads [CLAUDE.md](CLAUDE.md), and other agents read [AGENTS.md](AGENTS.md). Please:

- say in the issue or pull request that an agent helped, and which one,
- review what it wrote before you submit,
- run the build yourself, or say that you couldn't.

## Code of conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
