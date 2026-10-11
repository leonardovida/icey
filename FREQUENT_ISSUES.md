# Frequent Issues <!-- omit in toc -->

Also check [BREAKING_CHANGES.md](BREAKING_CHANGES.md) for changes between versions, and [docs/upstream-issues.md](docs/upstream-issues.md) for Ice bugs that Icey fixes.

- [Icey keeps asking for a permission that is already enabled](#icey-keeps-asking-for-a-permission-that-is-already-enabled)
- [My menu bar appearance settings are gone after upgrading](#my-menu-bar-appearance-settings-are-gone-after-upgrading)
- [Items are moved to the always-hidden section](#items-are-moved-to-the-always-hidden-section)
- [Icey removed an item](#icey-removed-an-item)
- [The Icey icon doesn't appear](#the-icey-icon-doesnt-appear)
- [The Menu Bar Layout pane keeps loading or is empty](#the-menu-bar-layout-pane-keeps-loading-or-is-empty)
- [An app quits or crashes after I hide its item](#an-app-quits-or-crashes-after-i-hide-its-item)
- [How do I quit or uninstall Icey?](#how-do-i-quit-or-uninstall-icey)
- [Icey shows a Dock icon when I show hidden items](#icey-shows-a-dock-icon-when-i-show-hidden-items)
- [I have both Ice.app and Icey.app installed](#i-have-both-iceapp-and-iceyapp-installed)
- [How do I solve the `Ice cannot arrange menu bar items in automatically hidden menu bars` error?](#how-do-i-solve-the-ice-cannot-arrange-menu-bar-items-in-automatically-hidden-menu-bars-error)

## Icey keeps asking for a permission that is already enabled

macOS ties Accessibility and Screen Recording to the app's signature. After you switch from Ice, or install a build you made yourself, System Settings can show the old entry as enabled although it no longer applies. Turning the switch off and on doesn't help.

1. Open System Settings > Privacy & Security > Accessibility (or Screen Recording).
2. Select Ice or Icey and click the minus button to remove it.
3. Click the plus button and add `Icey.app` (or `Ice.app` for releases before the rename) from Applications again.

Releases from GitHub are all signed with the same Developer ID, so this only needs doing once.

## My menu bar appearance settings are gone after upgrading

Upgrading from a version based on Ice 0.11.12 resets the menu bar appearance settings once. Set them again in Settings > Menu Bar Appearance. See [BREAKING_CHANGES.md](BREAKING_CHANGES.md).

## Items are moved to the always-hidden section

By default, macOS adds new items to the far left of the menu bar, which is also where the always-hidden section is (or the hidden section, if the always-hidden section is off). Most apps remember the positions of their items, but some don't, for example OneDrive and OpenVPN Connect. macOS treats the items of those apps as new items each time they appear, such as after a restart, so they end up hidden again, even if you moved them before.

Move them back in Settings > Menu Bar Layout. Remembering the positions of these items is tracked upstream in [jordanbaird/Ice#6](https://github.com/jordanbaird/Ice/issues/6) and [jordanbaird/Ice#26](https://github.com/jordanbaird/Ice/issues/26). [Open a feature request](https://github.com/leonardovida/icey/issues/new/choose) in Icey if you need it.

## Icey removed an item

Icey doesn't remove items. macOS probably put it in the always-hidden section. Option-click the Icey icon to show the always-hidden section, then Command-drag the item into a different section.

If a system item such as the clock or Wi-Fi is missing, turn it back on in System Settings > Menu Bar (or Control Center on older macOS).

## The Icey icon doesn't appear

If Icey is running but its icon is missing, the menu bar is probably out of room, for example next to the notch. Icey's icon may appear on a wider external display. Quit some menu bar apps, or reduce item spacing, until it appears.

On macOS 26 and later, also check that Icey is allowed in System Settings > Menu Bar. Turning it off there hides the Icey icon and the section dividers Icey needs to sort items.

## The Menu Bar Layout pane keeps loading or is empty

If the pane says "Loading menu bar items…" and never finishes, or says Icey's items are missing from the menu bar, Icey can't find its section divider in the menu bar. Follow the steps in [The Icey icon doesn't appear](#the-icey-icon-doesnt-appear), then quit and reopen Icey.

If the sections are empty or the icons are blank, check that Icey has Screen Recording permission. If System Settings already shows it as enabled, see [Icey keeps asking for a permission that is already enabled](#icey-keeps-asking-for-a-permission-that-is-already-enabled). Ice 0.11.12 always shows empty sections on macOS 26 Tahoe; Icey doesn't.

## An app quits or crashes after I hide its item

On macOS 26 and earlier, Icey hides items by moving them past the left edge of the screen. A few apps don't expect their item to be off screen and quit or crash a little later. Keep that app's item in the visible section, and report the crash to the app's developer.

## How do I quit or uninstall Icey?

To quit Icey, right-click the Icey icon and choose Quit Icey, or click Quit Icey in Settings > About. Icey normally runs without a Dock icon, so it doesn't appear in the Force Quit window. If you can't reach its menu, quit it in Activity Monitor: search for `Icey` (`Ice` for releases before the rename) and click the Stop button.

To uninstall Icey:

1. Quit Icey.
2. Move `Icey.app` (or `Ice.app`) from Applications to the Trash. If you installed Ice with Homebrew, run `brew uninstall --cask jordanbaird-ice` instead.
3. Optionally, remove Icey from System Settings > Privacy & Security > Accessibility and Screen Recording.
4. Optionally, delete your settings with `defaults delete com.jordanbaird.Ice`. Ice and Icey share these settings, so only do this if you won't use either again.

## Icey shows a Dock icon when I show hidden items

This comes from "Hide application menus" in Settings > Advanced. To hide another app's menus, Icey has to become the active app for a moment, and active apps appear in the Dock. Turn that setting off, or use the Ice Bar, which never hides application menus ([jordanbaird/Ice#906](https://github.com/jordanbaird/Ice/issues/906)).

## I have both Ice.app and Icey.app installed

Releases before the rename installed as `Ice.app`. Quit Icey, move `Ice.app` to the Trash, and open `Icey.app`. Both copies share a bundle identifier, so macOS can confuse them, for example by opening the old one at login. On macOS 27, a second copy can make macOS hide Icey's own icon, so there is nothing to click to show hidden items.

## How do I solve the `Ice cannot arrange menu bar items in automatically hidden menu bars` error?

1. Open `System Settings` on your Mac
2. Go to `Control Center` (`Menu Bar` on macOS 26 and later)
3. Set "Automatically hide and show the menu bar" to `Never`, as shown in the image below
4. Arrange your items in Settings > Menu Bar Layout
5. Set "Automatically hide and show the menu bar" back to your preferred setting

![Disable Menu Bar Hiding](https://github.com/user-attachments/assets/74c1fde6-d310-4fe3-9f2b-703d8ccb636a)
