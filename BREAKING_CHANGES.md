# Breaking changes

This page lists every Icey change that needs you to do something: settings that reset, permissions to grant again, or behavior that changed. The newest version is first.

What changed in each version is described in [GitHub Releases](https://github.com/leonardovida/icey/releases). That is the main place for updates. [CHANGELOG.md](CHANGELOG.md) is a short index of releases.

## 0.11.13-dev.2-icey.1

Release: [v0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1). Applies when you upgrade from Icey 0.11.12-icey.1 or from Ice 0.11.12.

| Change | What to do |
|---|---|
| The app is now named `Icey.app`, and its menus, settings and About pane say Icey. The bundle identifier is still `com.jordanbaird.Ice`, so settings, item layout and hotkeys carry over. | If you install by dragging from the DMG or with `Scripts/install.sh`, move the old `Ice.app` to the Trash afterwards. Keeping both confuses macOS, because they share a bundle identifier. |
| "Launch at login" is tied to the app's location. | If you used it with `Ice.app`, turn it off and on again in Settings > General after you remove `Ice.app`. |
| The process is now named `Icey`. | Scripts that use `pgrep -x Ice`, `killall Ice` or `log show --predicate 'process == "Ice"'` need the new name. `log show --predicate 'subsystem == "com.jordanbaird.Ice"'` works for both. |
| Menu bar appearance settings (tint, shadow, border, shape) reset once, during the upstream 0.11.13 settings migration. | Set them again in Settings > Menu Bar Appearance. Going back to a 0.11.12-based version won't restore them. |
| "Show section dividers" is replaced by "Section divider style". | Nothing. Your choice is migrated: on becomes the chevron style, off becomes no divider. |
| On macOS 27, the section divider style, "Hide application menus" and the temporary show interval have no effect, so they are hidden. Items without a bundle identifier can't be moved between sections. | Nothing. Disabled items show a tooltip that says why. |
| Coming from Ice or a build you made yourself: macOS treats Icey as a new app. | Grant Accessibility and Screen Recording again. If System Settings shows them as enabled but Icey still asks, remove Ice from the list and add it again. |
| Coming from Icey 0.11.12-icey.1: permissions carry over. | Nothing. |
| The built-in updater now uses Icey's GitHub releases instead of Ice's update feed. Earlier versions still check Ice's feed, so they never offer this release. | Install this release by hand once. After that, "Automatically check for updates" in Settings > About keeps Icey up to date. |

## 0.11.12-icey.1

Release: [v0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1). Applies when you switch from Ice 0.11.12.

| Change | What to do |
|---|---|
| Icey is signed with a different certificate than Ice, so macOS treats it as a new app. | Grant Accessibility and Screen Recording again. |
| The built-in updater still uses Ice's update feed, and could replace Icey with an upstream release. | Turn off "Automatically check for updates" in Settings > About, or upgrade to 0.11.13-dev.2-icey.1 or later, which uses Icey's own feed. |
| Accessibility reads that take longer than 1 second now fail and are retried later. | Nothing. This keeps a hung app from freezing Icey. |

## Applies to every version

- Icey uses Ice's bundle identifier, `com.jordanbaird.Ice`. Installing Icey replaces Ice, and the two share settings. You can't run both at once.
- To go back to Ice, quit Icey and install Ice's `Ice.app` in its place. Settings that a newer version migrated stay migrated (see above).
