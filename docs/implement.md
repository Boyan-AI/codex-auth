# Implementation Details

This document is the implementation index for `codex-auth`. Command-specific behavior lives in [docs/commands/README.md](./commands/README.md).

## Related Documents

- Command behavior: [docs/commands/README.md](./commands/README.md)
- API refresh and endpoint rules: [docs/api.md](./api.md)
- File permissions: [docs/permissions.md](./permissions.md)
- Schema migration: [docs/schema-migration.md](./schema-migration.md)
- Test organization: [docs/tests.md](./tests.md)
- CPA global service routing: [docs/cpa-smart-routing.md](./cpa-smart-routing.md)
- NewAPI local workbench: [docs/newapi-workbench.md](./newapi-workbench.md)
- Release and CI: [docs/release.md](./release.md)

## Runtime State

`codex-auth` stores local state under the resolved Codex home. The resolution order is:

1. `CODEX_HOME` when it is set to a non-empty existing directory
2. `HOME/.codex`
3. `USERPROFILE/.codex` on Windows

Managed files:

- `<codex_home>/auth.json`
- `<codex_home>/config.toml`
- `<codex_home>/accounts/registry.json`
- `<codex_home>/accounts/token-usage-cache.json`
- `<codex_home>/accounts/<account file key>.auth.json`
- `<codex_home>/accounts/backup/`
- `<codex_home>/accounts/auth.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/accounts/registry.json.bak.YYYYMMDD-hhmmss[.N]`
- `<codex_home>/sessions/...`

## Registry Compatibility

- `registry.json.schema_version` is the on-disk migration gate.
- `version = 2` registries using `active_email` and email-keyed snapshots are migrated to the current schema.
- Current-layout files that still use the top-level `version = 3` key are rewritten to the current schema.
- Loading a supported older schema performs the migration in memory and rewrites `registry.json` in the current format.
- Loading a newer `schema_version` is rejected with `UnsupportedRegistryVersion`.
- Saving always rewrites `registry.json` into the current schema field set.

See [docs/schema-migration.md](./schema-migration.md) for versioning policy and migration rules.

## Account Identity

`codex-auth` separates the user identity from the ChatGPT workspace/account context.

For ChatGPT OAuth auth:

- `chatgpt_account_id` stores the ChatGPT account context used by local matching and ChatGPT API headers.
- Account context selection is ordered:
  1. use non-empty `tokens.account_id`
  2. otherwise use non-empty JWT `https://api.openai.com/auth.chatgpt_account_id`
  3. otherwise use JWT `https://api.openai.com/auth.organizations[].id`
- `organizations[].id` is only a fallback for auth files that omit the legacy account id fields. When it is used, `chatgpt_account_id` is an `org-...` workspace identifier rather than the legacy UUID account id.
- Organization fallback chooses the organization with `is_default = true`; if none exists, it uses the first organization with a non-empty `id`.
- `chatgpt_user_id` is read from JWT auth claims, falling back to `user_id`.
- The local unique key is `record_key = chatgpt_user_id + "::" + chatgpt_account_id`; the second segment may be either a legacy account id or the organization fallback id.
- `account_key` stores this local `record_key`.
- Snapshot filenames are derived from `record_key`; filename-unsafe values are base64url-encoded.
- Email is normalized to lowercase and used for display/grouping, not identity.

For OpenAI API-key auth:

- `OPENAI_API_KEY` is read from `auth.json`.
- The key is verified with `GET https://api.openai.com/v1/me`.
- `email` from `/v1/me` is normalized to lowercase and used for display/grouping.
- The local unique key is `account_key = "apikey::" + me.id + "::" + sha256(OPENAI_API_KEY)`.
- The raw API key is stored only in the managed auth snapshot, never in `registry.json`, snapshot filenames, or display labels.
- API-key rows use a local `API key <fingerprint>` account label so multiple keys under the same email remain distinguishable.

## Auth Parsing

If `OPENAI_API_KEY` is present, the account is treated as API-key auth. Otherwise, ChatGPT auth requires:

- `tokens.access_token`
- `tokens.id_token`
- a ChatGPT account context from `tokens.account_id`, JWT `https://api.openai.com/auth.chatgpt_account_id`, or JWT `https://api.openai.com/auth.organizations[].id`
- JWT user identity from `chatgpt_user_id` or `user_id`

If required identity fields are missing or mismatched, import/login fails. Existing-registry foreground sync skips unsyncable auth files and continues with registry state already on disk.

## Active Auth Sync

Foreground account commands sync `auth.json` before their main work when the current auth file is parseable.

The sync flow is:

1. Read `~/.codex/auth.json`.
2. Parse email, plan, auth mode, `chatgpt_user_id`, and `chatgpt_account_id`.
3. Match by `record_key`.
4. Update the matching account and active key, or create a new account record when no match exists.
5. Rewrite the managed account snapshot when contents changed.

The empty-registry auto-import path still requires a parseable auth file. Once a registry exists, malformed or incomplete `auth.json` is skipped rather than deleting stored accounts.

## Backups and Cleanup

- `auth.json` backups are created only when contents change.
- `registry.json` backups are created only when contents change.
- Backups are stored under `~/.codex/accounts/` with local-time names.
- Same-second collisions get a `.N` suffix.
- The newest five managed backups are retained.
- `codex-auth clean` is whitelist-based for the current schema and affects only `~/.codex/accounts/`.

Command behavior for cleanup lives in [docs/commands/clean.md](./commands/clean.md).

## Local Usage Data

When API usage refresh is disabled, local usage refresh reads Codex rollout files under `~/.codex/sessions/**/rollout-*.jsonl`.

- The newest rollout file by `mtime` is scanned.
- The scanner looks for `type:"event_msg"` and `payload.type:"token_count"`.
- The last parseable `rate_limits` object in that file is used.
- Rollout events older than the current account activation time are ignored.
- Each account stores its own last consumed rollout signature.
- Rate limits map `window_minutes = 300` to 5h and `window_minutes = 10080` to weekly.
- Past reset timestamps render as `100%`.

Token totals use a separate per-rollout contribution cache. Incremental scans reuse a
file only when its path, size, and nanosecond modification time still match. Full
scans ignore existing entries and rewrite the cache. The cache contains aggregate
counts only, is stored with private permissions, and can be deleted safely because a
later scan rebuilds it from rollout files. Event timestamps are converted from UTC to
the running machine's local calendar date, so daily totals roll over at local 00:00.

## Desktop Refresh Coordination

- App launch reads local state, reconciles the persisted direct/CPA/NewAPI route, and then starts one background full Token scan.
- Opening the menu only reloads local state and does not perform network or Token work.
- The 60-second timer and manual refresh update quota data and then run an incremental Token scan.
- An incremental Token scan waits for the launch full scan before accessing the shared cache.
- Generation and state sequence counters prevent stale async results from replacing newer account or Token state.

CPA does not participate in quota or Token refresh coordination. The desktop app does not read CPA account data or poll CPA request events; Token totals remain derived from local rollout files.

The managed CPA runtime lives under `~/Library/Application Support/Codex Auth/CPA` and is controlled by the user-level `com.codex-auth.cpa` LaunchAgent. Its CPAMP management service uses `com.codex-auth.cpamp` and is started on demand for the management page, then stopped with the CPA gateway during route disable or app exit. The managed NewAPI runtime lives under `~/Library/Application Support/Codex Auth/NewAPI`, uses its own SQLite database, and is controlled by `com.codex-auth.newapi`. CPA and NewAPI own their respective account, channel, user, quota, and routing data. Codex Auth owns only the fixed local contracts, service lifecycle, protected client Token reference, and root-level `global_route` used to patch the shared Codex provider.


## Display Model

- Human-readable account displays group records by email.
- Group headers are not selectable; child account rows are selectable.
- Alias labels take precedence for child rows.
- Duplicate workspace-style plan labels may use stable numbered labels.
- `PLAN` comes from the auth claim when available, then falls back to usage snapshot plan data.
- Usage cells show remaining percentage plus reset time when reset data is known.
- `LAST ACTIVITY` is rendered as relative time from `last_usage_at`.

Command-specific display behavior lives in the relevant file under [docs/commands/](./commands/).

The macOS menu uses a 420-point popover with two conditional modes. Direct mode keeps the flat account list and existing management actions. NewAPI mode hides direct-account operations and shows only NewAPI/CPA health, native management links, disable, and quit. Selecting a row changes the fallback direct connection; while a managed proxy route is active, it does not replace the active global provider.
