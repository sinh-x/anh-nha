# Reproducible Build Configuration

This document describes how to build anh-nha APKs reproducibly — so that
anyone can produce a byte-identical APK to the official release, which is a
hard requirement for F-Droid's reproducible-build publication path.

## Prerequisites

- Flutter `stable` channel (pinned per release; see `fdroid-metadata.yml` `srclibs`)
- JDK 17
- Android SDK with:
  - `compileSdk = 36`
  - `buildToolsVersion = 37.0.0`
  - `ndkVersion = 29.0.14206865` (NDK r29)
- `pubspec.lock` is committed (it is) — this pins all Dart dependencies

## Reproducibility measures already in place

1. **`pubspec.lock` committed.** `flutter pub get` resolves to the exact
   versions recorded in the lock file, so Dart dependencies are deterministic
   across build hosts.
2. **No Google Play Services / Firebase.** The build has zero proprietary
   network-fetched SDK dependencies. Verified by `tools/check-no-play-services.sh`.
3. **No analytics.** `flutter config --no-analytics` is set in the F-Droid
   prebuild step so no telemetry is sent during the build and no analytics
   state is baked into the APK.
4. **`--no-tree-shake-icons`.** Tree-shaking of Material icons depends on the
   exact set of icons referenced, which can vary between analyzer versions.
   Disabling it keeps the asset bundle identical across hosts.
5. **Pinned NDK + build-tools.** `android/app/build.gradle.kts` pins
   `ndkVersion` and `buildToolsVersion` explicitly.
6. **No build-time secrets.** No API keys, server URLs, or credentials are
   baked into the APK. The Immich server URL and Tailscale peer are entered
   at runtime by the user.

## Local reproducible build

```bash
# 1. Clean any prior build artefacts
flutter clean

# 2. Resolve dependencies from the lock file
flutter pub get

# 3. Disable analytics (one-time per host)
flutter config --no-analytics

# 4. Build the release APK
flutter build apk --release --no-tree-shake-icons

# 5. Output:
#    build/app/outputs/flutter-apk/app-release.apk
```

## Verifying against an official release

```bash
# Download the official APK from GitHub Releases
sha256sum app-release.apk

# Build locally per the steps above, then:
sha256sum build/app/outputs/flutter-apk/app-release.apk

# The two checksums should match (note: F-Droid re-signs during publication,
# so for the F-Droid-published APK compare against the F-Droid build, not
# the GitHub release — see the note in fdroid-metadata.yml).
```

## What is NOT reproducible (and why)

- **APK signature block.** The v2/v3 signature is appended after the ZIP
  content and depends on the signing key. F-Droid handles this by stripping
  and re-signing; the unsigned ZIP content must match.
- **Gradle build cache.** Reproducibility assumes a clean build (`flutter
  clean` or a fresh checkout). Cached `.gradle` directories across hosts
  with different prior builds can in rare cases perturb timestamps inside
  the APK. Always build from a clean state for verification.

## CI

`.github/workflows/ci.yml` runs `flutter analyze` and `flutter build apk
--release` on every push/PR to `main`/`develop`. A future enhancement is to
publish the release APK SHA-256 on each tagged release so verifiers have a
reference hash.