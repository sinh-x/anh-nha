# ảnh nhà (anh-nha)

Custom Android photo sync client for self-hosted Immich server, accessible via Tailscale VPN.

Built with Flutter. Android 9+ (API 28). F-Droid distribution. No Google Play Services dependency.

## Status

v1.0.0 — feature-complete (Phases 1–7). See [ANH-001](https://github.com/sinh/anh-nha/issues/1) for requirements.

## Features

- Auto-upload photos to Immich over WiFi when Tailscale is connected
- Free local storage after verified sync (safe delete of synced photos)
- Visible offline sync queue with retry
- Multi-device family dashboard showing per-device sync status
- Backup integrity verification (checksum comparison)
- No telemetry, no analytics, no Google Play Services

## Documentation

- [Family install guide](docs/family-install-guide.md) — for non-technical family members
- [Reproducible build config](docs/reproducible-build.md) — how to build a byte-identical APK
- [Release notes template](docs/release-notes-template.md) — for cutting new releases
- [F-Droid metadata](fdroid-metadata.yml) — submission template for fdroiddata

## Build

```bash
flutter pub get
flutter analyze
flutter build apk --release --no-tree-shake-icons
```

See [docs/reproducible-build.md](docs/reproducible-build.md) for full reproducible-build instructions.

## License

MIT