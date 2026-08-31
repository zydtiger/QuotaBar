# Architecture

## Boundaries

```text
Codex app-server adapter      ZCode Coding Plan adapter
           |                            |
           +---- provider snapshots ----+
                         |
                 normalization layer
                         |
             SQLite cache and month ledger
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

The persistence layer owns schema creation, atomic replacement of mutable
current-period data, sealed ZCode month manifests, and snapshot freshness. It
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
