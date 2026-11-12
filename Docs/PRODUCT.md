# Product Contract

## Scope

QuotaBar is a personal macOS menu bar application with bundle identifier
`com.zyd.quotabar`. It supports exactly three subscription providers: Codex,
ZCode, and Claude.

QuotaBar reports two classes of metric that are never mixed:

- **Account metrics** are reported by a provider for the signed-in account and
  are cross-device: Codex and ZCode quota windows and token totals, and Claude
  quota windows. Device-local session logs must never feed or replace them.
- **Local activity** is counted per device from Claude Code transcripts on the
  devices the user configures as activity sources: tokens per day, user
  messages per day, and any further metric a source reports. It is always
  labelled with the devices it covers and is never added into account totals,
  the aggregate, or presented as an account total. Claude subscription accounts
  expose no account-level token or message history, so local activity is the
  only Claude usage history the app shows.

Local storage is a cache and normalized ledger for provider-account results and
per-source activity counts.

## Surfaces

The MVP has two top-level surfaces and no separate dashboard window.

### Menu Bar Panel

The panel is approximately 380 points wide and sizes to its content with no
minimum height, up to 620 points high. Taller content scrolls within that limit.
From top to bottom it contains:

1. Header, account-scope status, refresh status, and Settings action.
2. Account-token aggregate Today, 7 days, and Lifetime for enabled Codex and
   ZCode, titled with the providers it sums.
3. Codex provider card.
4. ZCode provider card.
5. Claude provider card.
6. Paired seven-day account-token chart for Codex and ZCode.
7. Chart legend, explicit Quit QuotaBar action, and manual refresh.

Codex and ZCode cards contain connection health, every quota window returned by
the provider, and Today, 7 days, and Lifetime account tokens. The Claude card
uses the same layout: connection health, a local-token row with Today, 7 days,
and 30 days titled with the enabled devices it covers, every quota window
returned by the provider, and a Local activity section with user messages for
the same periods and each device's freshness. Disabled providers are fully
removed and excluded from the aggregate.

The Claude local-token figure sums input, output, cache-read, and cache-write
tokens from every enabled activity source, counting a mirrored session once.
A caption under it breaks today's figure into output, cache read, and cache
write. Local activity starts with a 30-day backfill, so the card shows 30 days
instead of Lifetime, and the figure stays out of the account-token aggregate
and the seven-day account chart.

Token totals use compact `K`, `M`, and `B` units; values at or above one
billion use `B` so large account totals do not widen or crowd the cards.

Codex and Claude quota rows are data-driven. ZCode recognizes 5-hour and weekly pools;
MCP quota appears independently only when the provider reports an MCP limit.
Quota pools are never part of token totals.

### Settings Window

The resizable Settings window starts near 760 by 510 points. Its sidebar has:

- General: launch at login, menu bar text, refresh interval, refresh-on-open,
  and alert thresholds.
- Providers: Codex, ZCode, and Claude enable switches, credential consent
  switches for ZCode and Claude, account health, last poll, connection test,
  protocol/coverage details, and recovery actions.
- Activity Sources: the list of Claude activity sources with add, edit,
  remove, enable, and test actions, each source's device, freshness, and
  actionable failure state.
- Data & Privacy: timezone/day boundary, provider and activity coverage, cache
  diagnostics, and JSON or CSV export.

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

### Claude

Claude quota windows are account metrics read from the endpoint Claude Code's
`/usage` command uses: `GET https://api.anthropic.com/api/oauth/usage` with
the Claude Code OAuth access token and header `anthropic-beta: oauth-2025-04-20`.
The endpoint is undocumented; treat it as experimental and parse it
data-driven. The response's `limits` array lists every active window in
display order; each entry gives a `kind` (`session`, `weekly_all`,
`weekly_scoped`, or a future kind), a numeric `percent`, an optional
`resets_at` instant, and for scoped limits a `scope` whose `model` or `surface`
carries the `display_name` shown in the row. The 5-hour, weekly all-model, and
weekly per-model windows therefore render without the app naming a specific
model. An entry without a `kind` or a numeric `percent` is malformed. When
`limits` is absent, null, or empty, every top-level object that carries a
numeric `utilization` percentage (such as `five_hour` and `seven_day`) becomes
a window instead; null windows are omitted.

With explicit consent, read the access token and its expiry from the macOS
Keychain generic password `Claude Code-credentials` (JSON
`claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt`) through
`/usr/bin/security`, the same access path Claude Code uses. Never refresh or
rewrite the token, since that could invalidate Claude Code's own login. A
missing or expired token, or HTTP 401/403, is authentication-required: keep
the last snapshot as stale and ask the user to sign in with Claude Code.

## Local Activity Sources

An activity source is `{ name, argv, enabled, pipesCollector }`. The app runs
`argv` directly with `Process` (never through a shell). When `pipesCollector`
is set, the app writes the bundled collector script to the command's standard
input and appends `--since <UTC instant>` to `argv`; otherwise the command must
print the schema by itself. The app ships with one source, `This Mac`
(`python3 -`, piped). A remote device is a user-entered command such as
`ssh -o BatchMode=yes -o ConnectTimeout=15 <host> python3 -`. The app contains
no host names and no SSH-specific logic.

The bundled collector is stdlib-only Python 3.8+. It reads
`~/.claude/projects/**/*.jsonl` (or `$CLAUDE_CONFIG_DIR/projects`), skips files
not modified since `--since`, and prints counts only:

- `user_messages`: entries with `type` `user` that are not sidechain, meta,
  compact-summary, or transcript-only entries, whose content is typed text
  rather than a tool result, and whose text does not start with a harness
  marker. Deduplicated by entry `uuid`.
- `tokens`: assistant `message.usage` components `input`, `output`,
  `cache_read`, and `cache_creation`, kept separate and labelled with
  `message.model`. One API message can appear on several transcript lines, so
  it is deduplicated by message id and request id.

Schema `quotabar.activity`, version 1:

```json
{
  "schema": "quotabar.activity",
  "version": 1,
  "device": { "name": "host" },
  "generated_at": "2026-11-11T21:26:00Z",
  "since": "2026-11-04T00:00:00Z",
  "metrics": { "tokens": { "label": "Tokens", "unit": "tokens" } },
  "rows": [
    {
      "metric": "tokens",
      "bucket": "2026-11-11T21:00:00Z",
      "session": "session-id",
      "mirror": false,
      "labels": { "model": "model-id", "component": "output" },
      "value": 1200
    }
  ]
}
```

Buckets are UTC hour instants, so the day-boundary setting applies exactly as
it does to ZCode. A new metric needs only a new `metrics` entry and rows; the
panel shows metrics it does not know as generic Today and 7-day sums with the
reported label and unit. `mirror` marks a desktop-app SSH session's local
mirror (`ssh-<session>/<session>.jsonl`). When a session id appears in more
than one source, it is counted once: from a source where it is not a mirror,
else from the source with the larger total for that session.

Validation is strict: an unknown schema or version, a missing or mistyped
field, a non-hour bucket, a negative or non-finite value, or a row whose metric
is not declared rejects the whole output. Commands run with a timeout,
cancellation, and an output size limit. GUI apps start with a minimal `PATH`
and may lack `SSH_AUTH_SOCK`; the app resolves bare executable names through
`PATH` and common install locations, and failures name the category (command
not found, timed out, SSH connection or authentication failure, remote Python
missing, invalid output) without echoing command output.

Each successful run replaces that source's rows from the `--since` hour onward
atomically and keeps earlier days. An API message belongs to the hour of its
first transcript line, so a message that began before `--since` is not counted
again. The next run starts one hour before the
previous run's `generated_at`; the first run backfills 30 days. A failing or
unreachable source keeps its last successful data marked stale, never zero.
Removing a source deletes its stored rows; disabling it hides them. Changing a
source's command or piping may point it at another device, so it starts a new
history and its old rows are deleted.

## Totals and Coverage

- Provider Today and 7-day values are normalized in the user's selected day
  boundary. Codex `startDate` buckets remain date-only account labels rather
  than being reinterpreted as UTC-midnight instants. ZCode's offset-free
  provider timestamps are interpreted as UTC
  instants and retained that way in the ledger, so changing the display
  timezone never rewrites historical usage.
- Codex Lifetime is the provider-reported account lifetime estimate.
- ZCode Lifetime is the cached account total beginning 2025-01-01.
- Aggregate values sum only enabled Codex and ZCode account tokens. Claude
  quota windows and local activity never enter the aggregate.
- Quota percentages and MCP calls are never added to token totals.
- Local activity Today and 7-day values use the same day boundary and cover
  only enabled sources; the covered devices are always shown with them.
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
- Claude quota parsing handles missing, null, and unknown windows, and renders
  any weekly per-model window the provider reports.
- Missing consent, a missing or expired Claude token, and HTTP 401/403 show
  authentication-required with the last snapshot kept stale; the token is
  never refreshed or rewritten.
- Activity output that violates the schema is rejected; a failing, timed-out,
  or unreachable source keeps its prior rows as stale.
- A session mirrored on one device and native on another is counted once.
- Activity day totals follow the configured day boundary.
- Local activity never enters the account aggregate.
- Sources can be added, edited, removed, enabled, and tested in Settings and
  persist with preferences.
- Exports include account snapshots and per-source activity counts, without
  credentials, paths, or session text.
- Credentials and response bodies containing credentials never appear in logs,
  exports, or fixtures.
- Network and subprocess tests use deterministic fakes; tests do not consume
  live account quota or read the real Keychain. Collector tests use synthetic
  transcripts without real prompt text.
