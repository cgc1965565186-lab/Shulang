# Shulang 疏朗

[简体中文](README.md) | English

[![CI](https://github.com/cgc1965565186-lab/Shulang/actions/workflows/ci.yml/badge.svg)](https://github.com/cgc1965565186-lab/Shulang/actions/workflows/ci.yml)

**See your space. Clean with confidence.** Shulang is an open-source, native macOS app for understanding disk usage and reviewing files before moving them to the Trash. It runs locally without an account or telemetry.

Version 1.0.5 does not yet include complete app uninstallation or a notarized distribution. Full UI, accessibility, and large-scale GUI performance validation are still in progress. Review each item before cleaning; recovery depends on the Trash and the original destination remaining available.

## What it does

- **Scan and explore:** scan a folder, including readable hidden items, and browse results as a treemap, sunburst, or file list. Unreadable, excluded, and truncated areas are reported.
- **Review before cleaning:** start with nothing selected, inspect the matching rule and potential consequences, preview files, and confirm a plan before moving anything to the Trash. Imported rules are not treated as trusted built-in rules.
- **Find duplicate files:** compare file sizes, partial and full SHA-256 hashes, and finally the contents. Choose a copy to keep; it is checked again before a duplicate is moved.
- **Investigate possible leftovers:** compare common application-data locations with installed apps. A missing match is only a hint and requires manual review. The application inventory is read-only; full uninstall is not yet available.
- **Recover and inspect history:** cleanup records include per-item results. Interrupted operations can be investigated after restart; recovery conflicts and records without sufficient evidence are reported instead of being silently overwritten.
- **Compare scans:** export a metadata snapshot and compare compatible scans, including unambiguous renames. FSEvents can mark changed directories for rescanning, with a full-scan fallback when coverage cannot be trusted.

Logical size, estimated allocated size, and volume free space are different measurements. APFS clones and other shared storage mean that summing per-file allocation is not a reliable prediction of unique physical usage or immediately reclaimable space.

## Requirements and build

- macOS 14 or later; Xcode 27 / Swift 6.4 or later to build.
- No third-party SwiftPM dependencies.
- Full Disk Access is optional. Actual scan coverage depends on the permissions granted to the app.

```bash
git clone https://github.com/cgc1965565186-lab/Shulang.git
cd Shulang
swift test --disable-sandbox -j 1
./Scripts/build-app.sh
open -a "build/疏朗.app"
```

The script builds a universal app and CLI, generates an SPDX SBOM and checksums, and signs the app locally with an ad-hoc signature. It does **not** produce a Developer ID-signed or Apple-notarized release. An English README is available; the current app interface is in Chinese.

## Command line

```bash
build/shulang volumes
build/shulang scan ~/Downloads --hidden --snapshot-out snapshot.json
build/shulang diff ~/Downloads --hidden --snapshot snapshot.json
build/shulang duplicates ~/Downloads --hidden
build/shulang candidates ~/Downloads --markdown report.md
```

`--hidden` includes hidden items in CLI scans. Scans and reports are read-only; the CLI does not provide a permanent-delete command. Run `build/shulang --help` for the available commands.

## Privacy and safety

Shulang does not require an account or send telemetry. It does not alter SIP, Gatekeeper, or the TCC database. Cleanup moves approved items to the Trash rather than permanently deleting them. Not every item can necessarily be restored: the Trash contents may change, the original location may be occupied, or a filesystem operation may fail.

## Contributing and security

Issues and contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for building and testing, and [SECURITY.md](SECURITY.md) for private vulnerability reporting. Please use isolated fixtures for filesystem and deletion tests; do not include personal file paths or data in reports.

## License

[Apache License 2.0](LICENSE). Open-source references and license boundaries are documented in [docs/OPEN_SOURCE_AUDIT.md](docs/OPEN_SOURCE_AUDIT.md).
