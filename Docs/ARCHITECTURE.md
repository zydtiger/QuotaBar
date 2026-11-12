# Architecture

## Boundaries

```text
Codex app-server    ZCode Coding Plan    Claude OAuth usage     activity sources
    adapter              adapter              adapter          (argv commands)
       |                    |                    |                    |
       +--------- provider snapshots ------------+          activity reports
                         |                                            |
                 normalization layer                    validation and dedupe
                         |                                            |
             SQLite cache and month ledger ------- per-source activity rows
                         |
                application state model
                         |
              menu bar panel and settings
```

Provider adapters own authentication boundaries, transport, response
validation, and provider-specific semantics. They emit normalized immutable
snapshots and do not depend on SwiftUI.

The normalization layer owns day-boundary conversion and aggregate arithmetic.
It never adds overlapping token components or mixes token totals with quota
credits, percentages, MCP calls, or local client records.

Local activity is a separate pipeline, not a provider snapshot. An activity
source is a named argv command; the activity runner executes it with `Process`,
optionally piping the bundled collector to its standard input, enforces a
timeout, cancellation, and an output limit, and validates the
`quotabar.activity` schema strictly before anything is stored. Activity rows
are keyed by source, metric, UTC hour bucket, session, and labels. Cross-source
deduplication by session id and day-boundary arithmetic live in the
normalization layer; activity values never reach provider snapshots or the
account aggregate. The runner contains no host names or transport-specific
logic; SSH is only one possible user-entered command.

The persistence layer owns schema creation, atomic replacement of mutable
current-period data, sealed ZCode month manifests, snapshot freshness, and
per-source activity rows and source metadata (device name and last successful
`generated_at`). A successful activity run replaces that source's rows from its
`since` hour onward in one transaction and keeps earlier rows. It
must be injectable and use a temporary store in tests.

ZCode account buckets are stored as provider UTC instants, not pre-normalized
to the current UI timezone. The normalization layer applies the user's day
boundary when totals are queried.

The application model owns refresh orchestration and user settings. UI views
render model state and send intents; they do not perform network requests,
spawn processes, read credentials, or query SQLite directly.

## Concurrency

Use Swift structured concurrency. Isolate mutable UI state to the main actor.
Provider adapters and persistence operations expose `async` interfaces and are
injected behind protocols. Coalesce refresh requests and make cancellation
explicit. Do not use detached tasks for lifecycle work.

## Errors and Diagnostics

Convert transport and schema failures into typed, user-actionable states.
Diagnostics may include provider, operation, timestamp, HTTP status, protocol
version, and redacted error category. They must never include authorization
headers, raw credentials, prompts, responses, or arbitrary provider bodies.

## Credential Boundary

Codex authentication remains inside the signed-in Codex app-server process.
QuotaBar never reads a Codex token.

ZCode credential discovery is isolated behind a protocol. The initial personal
build may read the active local ZCode Coding Plan configuration with explicit
user consent. Pass the credential directly to the transport request, keep it
out of persisted models, and redact it from every error. A future distributable
build may migrate this boundary to a user-approved Keychain item without
changing provider or UI layers.

Claude credential discovery is isolated behind its own protocol and gated by an
explicit consent preference. It reads the `Claude Code-credentials` Keychain
item through `/usr/bin/security`, extracts only the OAuth access token and its
expiry, and passes the token directly to the usage request. QuotaBar never
refreshes or rewrites that token, never persists, logs, or exports it, and
treats a missing or expired token as authentication-required.

Activity sources never receive or return credentials. SSH authentication, if a
source uses SSH, stays inside the user's own SSH configuration and agent.
