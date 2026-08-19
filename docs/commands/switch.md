# `codex-auth switch`

## Usage

```shell
codex-auth switch -
codex-auth switch [--api|--skip-api]
codex-auth switch --live [--api|--skip-api]
codex-auth switch <query>
```

## Previous Switch

`codex-auth switch -` switches to the previous active account.

- `codex-auth -` is a shortcut for the same behavior.
- The command fails when no previous account has been recorded.
- The command fails when the recorded previous account was removed.
- `switch -` does not accept `--live`, `--api`, or `--skip-api`.

## Interactive Switch

`codex-auth switch` opens the account picker and exits after one successful switch.

- The picker uses the same account ordering as `list`.
- `q` quits without switching.
- `--api` forces foreground remote refresh before rendering.
- `--skip-api` renders from stored data and local-only active-account refresh where available.

## Live Switch

`codex-auth switch --live` keeps the picker open after each successful switch.

- The display refreshes on a timer.
- A successful switch patches the current display immediately.
- In-flight refresh results are discarded after a manual switch.
- Existing usage overlays stay visible until the next scheduled refresh.

## Query Switch

`codex-auth switch <query>` resolves the target from stored local data and does not run remote refresh.

Selectors can match:

- displayed row number,
- alias fragment,
- email fragment, or
- account name fragment.

If one account matches, it switches immediately. If multiple accounts match, the command falls back to interactive selection. Query mode does not accept `--live`, `--api`, or `--skip-api`.

## Switch Effects

When switching succeeds:

1. `auth.json` is backed up when its contents would change.
2. The selected account snapshot is copied to `~/.codex/auth.json`.
3. `active_account_key` is updated in `registry.json`.
4. `previous_active_account_key` records the account that was active before the switch, when one exists.
5. The success message uses the same identity label as singleton rows, for example `Switched to me(test@example.com)`.
6. When `global_route` is `direct`, `~/.codex/config.toml` is patched for the selected connection while unrelated settings, tables, comments, and file permissions are preserved.

ChatGPT account selections set the managed model and account defaults, and remove the API-key-only custom provider. API key selections use the CC Switch-compatible `model_provider = "custom"` and `[model_providers.custom]` format with the selected connection's Base URL. Switching does not manage `model_reasoning_effort`; an existing value is preserved, and an absent value continues to use the Codex default.

When `global_route` is `cpa` or `newapi`, switching still updates `auth.json`, `active_account_key`, and the fallback connection used after the managed route is disabled. It does not replace `model_provider = "codex_auth_cpa"` or `model_provider = "codex_auth_newapi"` in `config.toml`, and does not modify CPA or NewAPI-owned data.

Provider configuration changes apply to newly started Codex processes or threads. Existing processes do not reload `config.toml` automatically. Because Codex associates session visibility with the active model provider, sessions created with one provider may be hidden while another provider is active; switching the global route back makes those sessions visible again without deleting their files.
