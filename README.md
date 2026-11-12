# QuotaBar

[![CI](https://github.com/zydtiger/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/zydtiger/QuotaBar/actions/workflows/ci.yml)

QuotaBar is a native macOS menu bar utility for Codex, ZCode, and Claude
subscription usage. It shows provider quota windows; Today, 7-day, and Lifetime
account token totals for Codex and ZCode with their aggregate; and Claude local
activity (tokens and user messages per day) counted from Claude Code
transcripts on the devices you configure. Local activity is always labelled
with the devices it covers and never added into account totals.

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

Claude quota access is also opt-in: after consent the app reads Claude Code's
OAuth access token from the `Claude Code-credentials` Keychain item, sends it
only to Anthropic's usage endpoint, and never refreshes, rewrites, stores, or
exports it. If Claude Code's login has expired, the card asks you to sign in
with Claude Code again.

Claude local activity comes from activity sources managed in Settings. A source
is a named command whose output is the `quotabar.activity` JSON schema; the
bundled collector (`claude_activity_collector.py`, Python standard library
only) prints counts from `~/.claude/projects` and never prompt or response
text. The app ships with one local source. To add another machine, add a source
whose command pipes the collector over SSH, for example
`ssh -o BatchMode=yes -o ConnectTimeout=15 <host> python3 -`; nothing needs to
be installed on the remote host.

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
validates the project on `macos-latest`.

Versioned GitHub releases use semantic `vX.Y.Z` tags and include a universal
macOS ZIP for macOS 15 or later. Preview binaries are ad-hoc signed and are not
Developer ID signed or notarized, so macOS may block a downloaded build; build
from source when Gatekeeper trust is required. Release notes state the exact
signing status and the ZIP's SHA-256 digest.
