# Product Contract

## Scope

QuotaBar is a personal macOS menu bar application with bundle identifier
`com.zyd.quotabar`. It supports exactly two subscription providers: Codex and
ZCode. All headline usage is account-based and cross-device as reported by each
provider.

Device-local session logs must not feed provider or aggregate totals. Local
storage is a cache and normalized ledger for provider-account results.

## Surfaces

The MVP has two top-level surfaces and no separate dashboard window.

### Menu Bar Panel

The panel is approximately 380 points wide and at most 660 points high. From
top to bottom it contains:

1. Header, account-scope status, refresh status, and Settings action.
2. Aggregate Today, 7 days, and Lifetime.
3. Codex provider card.
4. ZCode provider card.
5. Paired seven-day provider token chart.
6. Provider legend and manual refresh.

Each provider card contains connection health, every quota window returned by
the provider, and Today, 7 days, and Lifetime tokens. Disabled providers are
fully removed and excluded from the aggregate.

Codex quota rows are data-driven. ZCode recognizes 5-hour and weekly pools;
MCP quota appears independently only when the provider reports an MCP limit.
Quota pools are never part of token totals.

### Settings Window

The resizable Settings window starts near 760 by 510 points. Its sidebar has:

- General: launch at login, menu bar text, refresh interval, refresh-on-open,
  and alert thresholds.
- Providers: Codex and ZCode enable switches, account health, last poll,
  connection test, protocol/coverage details, and recovery actions.
- Data & Privacy: timezone/day boundary, provider coverage, cache diagnostics,
  and JSON or CSV export.

The panel Settings action and Command-comma open the same window.

## Account Sources

### Codex

Use a persistent `codex app-server --stdio` JSON-RPC subprocess under the
currently signed-in account:

- Send JSON-RPC `initialize` with QuotaBar client information, then the
  `initialized` notification before account requests.
- `account/usage/read` for `summary.lifetimeTokens` and daily account buckets.
- `account/rateLimits/read` for quota windows.
- `account/rateLimits/updated` notifications between polls where available.

Treat the protocol as experimental. Validate response shapes, redact errors,
and show stale data if the bridge becomes unavailable. Never fall back to local
session totals.

### ZCode

Use the active Z.ai Coding Plan account endpoint and credential without logging
or persisting the credential in application data:

- `GET /api/monitor/usage/model-usage?startTime=...&endTime=...`
- `GET /api/monitor/usage/quota/limit`

With explicit consent, read the enabled `builtin:zai-coding-plan` entry from
`~/.zcode/v2/config.json`; use its `options.apiKey` and `options.baseURL`
to derive the configured scheme/host/port origin before constructing the
absolute monitor paths, without logging or persisting either. The usage API
uses `yyyy-MM-dd HH:mm:ss` query values and reports parallel hourly
`x_time`/`tokensUsage` buckets. Quota `unit: 3, number: 5` maps to the 5-hour
pool and `unit: 6, number: 1` maps to the weekly pool. MCP is rendered only
when a provider-returned MCP limit exists.

ZCode Lifetime is the sum of account usage from 2025-01-01 through the current
time. Backfill closed calendar months in requests of at most 31 days. Cache and
seal every successful historical month so normal refresh never requests it
again. Keep the current month unsealed and refresh it incrementally.

## Totals and Coverage

- Provider Today and 7-day values are normalized in the user's selected day
  boundary. Codex `startDate` buckets remain date-only account labels rather
  than being reinterpreted as UTC-midnight instants. ZCode's offset-free
  provider timestamps are interpreted as UTC
  instants and retained that way in the ledger, so changing the display
  timezone never rewrites historical usage.
- Codex Lifetime is the provider-reported account lifetime estimate.
- ZCode Lifetime is the cached account total beginning 2025-01-01.
- Aggregate values sum only enabled providers for the same metric.
- Quota percentages and MCP calls are never added to token totals.
- Show the ZCode lifetime boundary in Settings and explanatory UI while the
  panel label remains `Lifetime`.

## Refresh and State

Hydrate the cache and start periodic refresh at menu-bar startup. An optional
panel-open refresh is controlled separately. Coalesce concurrent refreshes and
apply capped exponential backoff after failures.

Every provider supports loading, fresh, stale, disabled, unavailable, and
authentication-required states. Preserve the last successful snapshot with its
timestamp. Never replace an error with zero usage.

## Acceptance Criteria

- The generated project builds and tests with the documented command.
- The app runs as an agent-style menu bar application without a Dock icon.
- The panel and Settings match the documented hierarchy in light and dark mode.
- Provider enable switches cancel in-flight provider polling, stop future polling,
  and exclude the provider from totals.
- Codex parsing handles missing and changing quota windows.
- ZCode parsing recognizes 5-hour, weekly, and MCP limits.
- Historical ZCode months are requested once, cached, sealed, and recovered
  safely after interruption.
- Today, 7-day, Lifetime, and enabled-provider aggregate calculations have unit
  tests, including day-boundary behavior.
- Credentials and response bodies containing credentials never appear in logs,
  exports, or fixtures.
- Network and subprocess tests use deterministic fakes; tests do not consume
  live account quota.
