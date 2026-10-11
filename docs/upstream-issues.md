# Upstream Ice issues and their status in Icey

This page maps bugs reported against [Ice](https://github.com/jordanbaird/Ice) (jordanbaird/Ice) to their status in Icey. If you hit one of these in Ice, [install Icey](../README.md#install) instead. Icey replaces Ice and keeps your settings.

Each fix is described in the [release](https://github.com/leonardovida/icey/releases) that ships it. Issue titles are quoted as they appear upstream. To report a problem that isn't listed, [open an issue in Icey](https://github.com/leonardovida/icey/issues/new/choose).

## Fixed in Icey

| Upstream issue | Title | Fixed in |
|---|---|---|
| [#334](https://github.com/jordanbaird/Ice/issues/334) | Ice has noticeable energy impact during mouse movement | [0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1) |
| [#479](https://github.com/jordanbaird/Ice/issues/479) | Energy impact | [0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1) |
| [#578](https://github.com/jordanbaird/Ice/issues/578) | High CPU usage | [0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1) |
| [#819](https://github.com/jordanbaird/Ice/issues/819) | memory leak in WindowServer caused by Ice? | [0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1) (reduces captures) |
| [#530](https://github.com/jordanbaird/Ice/issues/530) | high memory usage | [0.11.12-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.12-icey.1) |
| [#973](https://github.com/jordanbaird/Ice/issues/973) | Menu bar layout shown nothing on the sections | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#951](https://github.com/jordanbaird/Ice/issues/951) | Can't view the icons on Menu Bar Layout | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#999](https://github.com/jordanbaird/Ice/issues/999) | Can't see layout | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#954](https://github.com/jordanbaird/Ice/issues/954) | Ice in menu bar not working anymore (MacOS Golden Gate 27) | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) (early macOS 27 support) |
| [#1014](https://github.com/jordanbaird/Ice/issues/1014) | With an app item among the system items, clicking the battery opens that app and Wi-Fi does not open | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#947](https://github.com/jordanbaird/Ice/issues/947) | app crash after click in menubar | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#977](https://github.com/jordanbaird/Ice/issues/977) | crashes whenever I use the trigger button in the menu bar | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#925](https://github.com/jordanbaird/Ice/issues/925) | Crash when enabling "Use Ice Bar" with Dynamic location | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#969](https://github.com/jordanbaird/Ice/issues/969) | update dialog keeps open and cannot be closed after launch | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#937](https://github.com/jordanbaird/Ice/issues/937) | Check for automatic updates keeps appearing when clicking | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#931](https://github.com/jordanbaird/Ice/issues/931) | Check for updates automatically dialog box doesnt accept input | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#986](https://github.com/jordanbaird/Ice/issues/986) | Ice Bar leaves a ghost/visual artifact on the primary display when a video enters fullscreen on a secondary display | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#959](https://github.com/jordanbaird/Ice/issues/959) | Split menu bar does not function like expected in full screen | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#988](https://github.com/jordanbaird/Ice/issues/988) | Ice Bar fullscreen expansion behaves differently depending on which display contains the active window | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |
| [#968](https://github.com/jordanbaird/Ice/issues/968) | Ice stuck / menu bar stays hidden after form dropdown hang | [0.11.13-dev.2-icey.1](https://github.com/leonardovida/icey/releases/tag/v0.11.13-dev.2-icey.1) |

## Partly addressed

| Upstream issue | Title | Status |
|---|---|---|
| [#1004](https://github.com/jordanbaird/Ice/issues/1004) | Unable to proceed past permissions request. | Icey explains what to do when System Settings shows a permission as enabled but it doesn't apply: remove Ice from the list and add it again. |
| [#929](https://github.com/jordanbaird/Ice/issues/929) | Menu bar scaling and layout issues on external/built-in displays | Item images now use the scale of the display they were captured on. Not yet confirmed on a two-display setup. |

## Open in Icey too

These need a reproduction or more information. If you can reproduce one in Icey, please [open an issue](https://github.com/leonardovida/icey/issues/new/choose) with your macOS version and steps.

| Upstream issue | Title |
|---|---|
| [#946](https://github.com/jordanbaird/Ice/issues/946) | MacOS Tahoe 26.5 update broke hidden elements in ice layout |
| [#957](https://github.com/jordanbaird/Ice/issues/957) | Starts but nothing much more |

## Not a bug in Ice or Icey

| Upstream issue | Title | What to do |
|---|---|---|
| [#930](https://github.com/jordanbaird/Ice/issues/930) | Removed icon from tray and can't get it back | Turn the icon back on in System Settings > Menu Bar. |
| [#934](https://github.com/jordanbaird/Ice/issues/934) | Nothing happens when I try to run Ice | The Ice icon is running but has no room in the menu bar, for example next to the notch. It shows up on a wider external display. Hide or remove other items, or reduce item spacing. |

## Upstream pull requests included in Icey

Icey includes these community pull requests that upstream Ice has not merged. Their authors are credited in the commits.

- [#995](https://github.com/jordanbaird/Ice/pull/995): restore hiding, the Ice Bar and the layout editor on macOS 27.
- Follow-ups from [#1001](https://github.com/jordanbaird/Ice/issues/1001): remaining macOS 27 gaps.
- [#953](https://github.com/jordanbaird/Ice/pull/953) and [#950](https://github.com/jordanbaird/Ice/pull/950): helper connection on macOS 26 (adapted).
- [#956](https://github.com/jordanbaird/Ice/pull/956), [#967](https://github.com/jordanbaird/Ice/pull/967): crash fixes (adapted).
- [#945](https://github.com/jordanbaird/Ice/pull/945), [#870](https://github.com/jordanbaird/Ice/pull/870): update prompt fixes (adapted).
- [#928](https://github.com/jordanbaird/Ice/pull/928): pick up permissions granted after launch (adapted).
- [#922](https://github.com/jordanbaird/Ice/pull/922), [#942](https://github.com/jordanbaird/Ice/pull/942), [#972](https://github.com/jordanbaird/Ice/pull/972), [#1012](https://github.com/jordanbaird/Ice/pull/1012): smaller fixes.
