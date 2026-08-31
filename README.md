# QuotaBar

[![CI](https://github.com/zydtiger/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/zydtiger/QuotaBar/actions/workflows/ci.yml)

QuotaBar is a native macOS menu bar utility for account-based Codex and ZCode
subscription usage. It shows provider quota windows, Today, 7-day, and Lifetime
token totals, and an enabled-provider aggregate without substituting local
device history for account data.

## Usage and privacy

Open the menu bar panel to refresh account data and use its Settings action (or
Command-comma) for provider controls, refresh behavior, timezone day boundary,
launch at login, and JSON/CSV export. Disabled providers stop polling and are
excluded from aggregate totals.

Codex is read through the signed-in `codex app-server` process. ZCode access is
opt-in: the app only discovers the enabled local Coding Plan configuration in
`~/.zcode/v2/config.json` after the setting is enabled, uses its configured API
origin directly, and never stores or exports its credential. SQLite stores
normalized account snapshots and sealed monthly ZCode ledger entries; it never
stores prompts, raw responses, or local session logs.

## Development

Requirements:

- macOS 15 or later
- Xcode 26 or later
- XcodeGen and `prek` (`brew install xcodegen prek`)

Activate the repository hooks once per clone:

```sh
prek install
```

This installs fast checks at `pre-commit`, the commit-subject policy at
`commit-msg`, and the generated-project/test gate at `pre-push`.

Generate and build:

```sh
xcodegen generate
xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Run tests:

```sh
xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Run the same repository gates used for handoff and future CI:

```sh
prek run --all-files
prek run --hook-stage pre-push --all-files
```

The generated Xcode project is checked in for convenient local use, but
`project.yml` remains authoritative.

## Distribution

QuotaBar is published as source under the [MIT License](LICENSE). GitHub Actions
validates the project on `macos-latest`. No binary release, Developer ID
signing, notarization, or Mac App Store distribution is currently configured.
