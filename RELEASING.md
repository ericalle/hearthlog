# Cutting a release

1. Bump the version in all three TOC files and `ns.VERSION` in `Hearthlog/Util.lua` (they must match the tag).
2. Add a section to `CHANGELOG.md`.
3. `python3 tools/smoke_test.py` must pass.
4. Commit, then tag and push the tag to GitHub:

```sh
git tag v0.3.0
git push github main --tags
```

The `release` workflow zips `Hearthlog/`, writes `release.json`, and publishes a GitHub Release.
Friends on WowUp get the update automatically; everyone else downloads the zip from
https://github.com/ericalle/hearthlog/releases/latest and extracts it over `Interface/AddOns/Hearthlog`.
Settings and recordings live in `WTF/`, so replacing the addon folder never touches them.

Remotes: Forgejo is the working remote (`origin`); GitHub is the public mirror (`github`).
