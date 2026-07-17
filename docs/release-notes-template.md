# Release Notes Template

Copy this file to `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`
(or `<versionName>.txt` for GitHub Releases) for each release. Keep the
changelog user-facing — short, plain language. F-Droid's `changelogs/` files
must be named by **versionCode** (integer), not versionName.

## Template

```
anh-nha <versionName>

New:
- <one-line feature>

Improved:
- <one-line improvement>

Fixed:
- <one-line bug fix>

Notes:
- <upgrade/migration note or none>
```

## Rules

- Max 500 chars per F-Droid changelog file.
- Plain text only — no Markdown, no HTML.
- Write in the user's voice; no internal ticket IDs.
- If a release has only fixes, drop the "New" / "Improved" sections.

## Example — 1.0.0 (already shipped)

See `fastlane/metadata/android/en-US/changelogs/1.0.0.txt`.

## Where release notes live

| Audience | Path | Format |
|---|---|---|
| F-Droid | `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` | Plain text, ≤500 chars |
| GitHub Releases | https://github.com/sinh/anh-nha/releases/tag/v<versionName> | Markdown, full length |
| In-app | (future) `lib/release_notes/<versionName>.md` | Markdown rendered |

## Publishing a release

1. Bump `version: X.Y.Z+N` in `pubspec.yaml` (N = versionCode).
2. Update `CurrentVersion` / `CurrentVersionCode` in `fdroid-metadata.yml`.
3. Add a `fastlane/metadata/android/en-US/changelogs/<N>.txt` entry.
4. Tag: `git tag vX.Y.Z && git push --tags`.
5. Build the release APK (see `docs/reproducible-build.md`).
7. Create a GitHub Release with the tag and attach the APK + SHA-256.
8. Submit an MR to fdroiddata bumping `CurrentVersion`/`CurrentVersionCode`
   and the `Builds:` entry's `commit:` to the new tag.