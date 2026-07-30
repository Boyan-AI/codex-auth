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
codex-auth gui smart-pool <account-key> include|exclude
codex-auth gui cpa-sync <account-key> include|exclude <auth-dir>
codex-auth gui alias set <account-key> <alias>
codex-auth gui alias clear <account-key>
codex-auth gui import <path> [--alias <alias>]
codex-auth gui login [--device-auth]
```

`state` reads stored registry data and syncs the active `auth.json` when possible.
`refresh` also runs the existing foreground usage refresh path before returning state.

`stats` scans local Codex rollout JSONL files and returns token usage aggregates. It
uses deltas between successive `total_token_usage` snapshots, so repeated snapshots
from rate-limit updates are not counted twice. The result is local telemetry and is
not an official subscription bill or quota ledger. `today` is the current UTC day;
`days` contains the complete daily series so the macOS app can aggregate it into
daily, weekly, monthly, and yearly charts. The default mode reuses unchanged per-file
contributions from `accounts/token-usage-cache.json`; `--full` reparses every rollout
file and replaces the cache.

Token stats fields:

- `summary`: all scanned token totals.
- `today`: current UTC day total, or `null` when there is no usage today.
- `days`: daily totals with `date`, `sessions`, and `totals`.
- `latest_day`: retained for compatibility with the first preview version.
- `quality`: scanner diagnostics for CLI troubleshooting; the macOS app does not show this field.
Mutation commands return the updated state after saving.

## State JSON

The response excludes raw access tokens, refresh tokens, ID tokens, and API keys.

Top-level fields:

- `schema_version`: registry schema version.
- `codex_home`: resolved Codex home path.
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
- `smart_pool_enabled`: whether the account participates in CPA smart routing; it does not change the active direct account.
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

`gui switch <account-key>` has the same account activation semantics as the CLI switch path:
it replaces the active auth file and saves the registry. It affects new Codex CLI sessions.
Already-running `codex` processes are not modified.

`gui smart-pool <account-key> include|exclude` only changes routing membership. It
does not replace `auth.json`, switch the active direct account, or authenticate the
account with CPA.

`gui cpa-sync <account-key> include|exclude <auth-dir>` applies that membership to an
independent CPA directory. `include` writes the selected ChatGPT account using the CPA
export format; `exclude` removes only the deterministic file for that account. The
desktop app invokes this command after the membership state has been saved.
