# Frequent Issues <!-- omit in toc -->

Also check [BREAKING_CHANGES.md](BREAKING_CHANGES.md) for changes between versions, and [docs/upstream-issues.md](docs/upstream-issues.md) for Ice bugs that Icey fixes.

- [Icey keeps asking for a permission that is already enabled](#icey-keeps-asking-for-a-permission-that-is-already-enabled)
- [My menu bar appearance settings are gone after upgrading](#my-menu-bar-appearance-settings-are-gone-after-upgrading)
- [Items are moved to the always-hidden section](#items-are-moved-to-the-always-hidden-section)
- [Icey removed an item](#icey-removed-an-item)
- [The Icey icon doesn't appear](#the-icey-icon-doesnt-appear)
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

By default, macOS adds new items to the far left of the menu bar, which is also where the always-hidden section is. Most apps remember the positions of their items, but some don't. macOS treats the items of those apps as new items each time they appear, so they end up in the always-hidden section, even if you moved them before.

Move them back in Settings > Menu Bar Layout. Remembering the positions of these items is tracked upstream in [jordanbaird/Ice#6](https://github.com/jordanbaird/Ice/issues/6) and [jordanbaird/Ice#26](https://github.com/jordanbaird/Ice/issues/26). [Open a feature request](https://github.com/leonardovida/icey/issues/new/choose) in Icey if you need it.

## Icey removed an item

Icey doesn't remove items. macOS probably put it in the always-hidden section. Option-click the Icey icon to show the always-hidden section, then Command-drag the item into a different section.

If a system item such as the clock or Wi-Fi is missing, turn it back on in System Settings > Menu Bar (or Control Center on older macOS).

## The Icey icon doesn't appear

If Icey is running but its icon is missing, the menu bar is probably out of room, for example next to the notch. Icey's icon may appear on a wider external display. Quit some menu bar apps, or reduce item spacing, until it appears.

## How do I solve the `Ice cannot arrange menu bar items in automatically hidden menu bars` error?

1. Open `System Settings` on your Mac
2. Go to `Control Center` (`Menu Bar` on macOS 26 and later)
3. Set "Automatically hide and show the menu bar" to `Never`, as shown in the image below
4. Arrange your items in Settings > Menu Bar Layout
5. Set "Automatically hide and show the menu bar" back to your preferred setting

![Disable Menu Bar Hiding](https://github.com/user-attachments/assets/74c1fde6-d310-4fe3-9f2b-703d8ccb636a)
