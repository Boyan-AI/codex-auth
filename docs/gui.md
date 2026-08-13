# GUI Backend

`codex-auth gui` is the machine-readable backend used by the macOS menu bar app.
It is intended for local GUI integration and prints JSON to stdout.

CLI help, diagnostics, and flags remain English. The SwiftUI app translates common
results and failures into Chinese UI text.

## Commands

```shell
codex-auth gui state [--active] [--api|--skip-api]
codex-auth gui refresh [--active] [--api|--skip-api]
codex-auth gui stats [--full]
codex-auth gui switch <account-key>
codex-auth gui remove <account-key>
codex-auth gui alias set <account-key> <alias>
codex-auth gui alias clear <account-key>
codex-auth gui cpa-route enable <base-url> <client-config-path>
codex-auth gui cpa-route disable
codex-auth gui import <path> [--alias <alias>]
codex-auth gui login [--device-auth]
```

`state` reads stored registry data and syncs the active `auth.json` when possible.
`refresh` also runs the existing foreground usage refresh path before returning state.

`stats` scans local Codex rollout JSONL files and returns token usage aggregates. It
uses deltas between successive `total_token_usage` snapshots, so repeated snapshots
from rate-limit updates are not counted twice. The result is local telemetry and is
not an official subscription bill or quota ledger. `today` is the current local
calendar day and rolls over at local midnight;
`days` contains the complete daily series so the macOS app can aggregate it into
daily, weekly, monthly, and yearly charts. The default mode reuses unchanged per-file
contributions from `accounts/token-usage-cache.json`; `--full` reparses every rollout
file and replaces the cache.

Token stats fields:

- `summary`: all scanned token totals.
- `today`: current local calendar-day total, or `null` when there is no usage today.
- `days`: daily totals with `date`, `sessions`, and `totals`.
- `latest_day`: retained for compatibility with the first preview version.
- `quality`: scanner diagnostics for CLI troubleshooting; the macOS app does not show this field.
Mutation commands return the updated state after saving.

## State JSON

The response excludes raw access tokens, refresh tokens, ID tokens, and API keys.

Top-level fields:

- `schema_version`: registry schema version.
- `codex_home`: resolved Codex home path.
- `global_route`: `direct` or `cpa`; this is the route used by newly started Codex processes sharing this Codex home.
- `active_account_key`: active account key or `null`.
- `generated_at`: Unix timestamp in seconds.
- `reset_credits`: reset opportunities for the active ChatGPT account during a GUI refresh, or `null` when unavailable.
- `refresh`: refresh metadata.
- `warnings`: reserved string array.
- `accounts`: account rows.

Account fields:

- `account_key`
- `display_name`
- `alias`
- `email`
- `account_name`
- `plan`
- `auth_mode`
- `is_active`
- `reset_credits`: reset opportunities for this account during a GUI refresh, or `null` when the query failed or was skipped.
- `usage.five_hour`: usage window object or `null` when the API does not explicitly report a 300-minute window.
- `usage.seven_day`
- `last_usage_at`
- `last_refresh_at`

Usage window fields:

- `status`: `ok` or `unknown`.
- `remaining_percent`: integer percentage or `null`.
- `total`: currently `100` when known.
- `used`: integer used percentage or `null`.
- `reset_at`: Unix timestamp in seconds or `null`.

Reset credit fields:

- `available_count`: number of Codex rate-limit resets that can be applied directly.
- `expires_at`: earliest expiration timestamp among available reset credits, or `null`.

## Switching Semantics

`gui switch <account-key>` has the same account activation semantics as the CLI switch path: it replaces the active auth file and saves the registry. In `direct` mode it also selects that connection's Codex provider settings. In `cpa` mode it updates only the fallback direct connection; the global CPA provider remains selected. Already-running `codex` processes are not modified.

`gui cpa-route enable` validates a loopback Base URL and absolute client configuration path, patches the shared Codex configuration to use `codex_auth_cpa`, then persists `global_route = "cpa"`. The client Key remains in the protected configuration file and is not accepted as a command argument. The installed command authentication helper validates macOS system routing and environment proxies independently: unsafe manual system proxies, PAC, or auto-discovery fail closed, while `NO_PROXY` can exclude only a non-loopback environment proxy.

`gui cpa-route disable` restores the currently selected fallback direct connection before persisting `global_route = "direct"`. The desktop app is responsible for starting and validating CPA before `enable`, and for stopping CPA only after `disable` succeeds.
