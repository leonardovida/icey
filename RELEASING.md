# Releasing Icey

For the maintainer. Building needs the Developer ID certificate, the `icey-notary` notarization profile and the Sparkle key `icey`, which are all in the maintainer's login keychain.

## Steps

From an up-to-date `main` with everything merged:

```sh
TAG=v0.11.13-dev.2-icey.2                     # the new version

Scripts/bump-version.sh $TAG                  # 1. version and build number
cp release-notes/TEMPLATE.md release-notes/$TAG.md
#                                               2. write the notes, add a CHANGELOG.md line,
#                                                  and BREAKING_CHANGES.md rows if users must act
#                                               3. commit, open a PR, merge it, then git pull
Scripts/package-release.sh $TAG               # 4. build, sign, notarize (about 10 minutes)
Scripts/publish-release.sh $TAG               # 5. publish and check the update feed
```

That's it. After step 5, GitHub checks the release's update feed, then rebuilds the [website](https://leonardovida.github.io/icey/) so its download button points at the new DMG. Installed copies see the update within a day, or right away from Settings > About > Check for Updates.

To check a release before publishing it, run `DRY_RUN=1 Scripts/publish-release.sh $TAG`.

## Release notes

Short and plain, for users. Use [release-notes/TEMPLATE.md](release-notes/TEMPLATE.md) and leave out sections you don't need:

- **Highlights:** two or three bullets.
- **Upgrading:** only when users must do something.
- **Bug fixes:** one line per fix, saying what users saw and what happens now. Link to the [fixes page](https://leonardovida.github.io/icey/fixes/) instead of listing every issue.
- **Compatibility:** each change that needs action, with what to do.

Never add a testing or verification section. That belongs in the pull request.

## Tracking fixed Ice issues

[docs/issues.json](docs/issues.json) lists every upstream Ice issue Icey has looked at. When a fix ships:

1. Add or update the issue there, with `fixed_in` set to the release tag.
2. Run `Scripts/build-site.py --docs` to regenerate [docs/upstream-issues.md](docs/upstream-issues.md).

The website builds its "Ice bugs fixed" pages from the same file.

## If something goes wrong

- **A script stops with an error:** it says what to fix. Nothing is published until `publish-release.sh` passes all its checks.
- **The release was turned back into a draft:** the "Check release appcast" workflow found no valid `appcast.xml`. Run `Scripts/package-release.sh $TAG` again, replace the draft's assets with the files in `build/release/$TAG/`, and publish the draft again.
- **The website didn't update:** run `gh workflow run website.yml --repo leonardovida/icey`. GitHub runs release workflows from the tagged commit, so a release tagged on a commit older than the workflows (v0.11.13-dev.2-icey.1 and earlier) skips both the appcast check and the website deploy.

Never publish from the GitHub website, and never mark a release that users should get as a prerelease: the update feed skips prereleases.
