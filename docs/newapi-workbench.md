# NewAPI Local Workbench

This document defines the local macOS workbench that combines Codex Auth, NewAPI, and CLIProxyAPI (CPA).

## Architecture

- Codex Auth is the menu bar controller and keeps one fallback direct ChatGPT account or API Key selected.
- NewAPI is the unified API exit. It owns channels, users, distributed Tokens, quotas, and routing policy through its native web UI.
- CPA is the required managed upstream when Codex Auth enables NewAPI automatically. It converts subscription accounts and OAuth sessions into an OpenAI-compatible local API.
- CPA Manager Plus (CPAMP) is the local CPA management page service. Codex Auth starts it only when the CPA management page is opened and stops it with the other managed services.
- Codex Auth does not copy or reconcile NewAPI users or CPA accounts. It owns exactly one explicitly marked NewAPI channel named `Codex Auth CPA`, which connects the managed local CPA as the default upstream. Other NewAPI channels remain user-owned.

New Codex processes use one of these routes:

- `direct`: the selected Codex Auth account or direct API Key.
- `newapi`: `http://127.0.0.1:3000/v1` through the `codex_auth_newapi` provider.
- `cpa`: the legacy `codex_auth_cpa` provider, retained for registry and CLI compatibility but no longer exposed as the desktop product mode.

## Runtime And Data

The managed NewAPI runtime is pinned to `v1.0.0-rc.25` and uses the official macOS binary with SHA-256 `c287e317f5bbd8112e24af40523525a330a933047082e61308a1b8603d7e485e`.

The upstream macOS asset reports `v0.0.0` from `--version` and the public status endpoint because its release build lacks stamped version metadata. The fixed official SHA-256 is therefore the authoritative asset identity; Codex Auth records the managed contract version as `v1.0.0-rc.25`.

- Runtime root: `~/Library/Application Support/Codex Auth/NewAPI`
- SQLite database: `data/new-api.db`
- Client configuration: `client.json`, mode `0600`
- Server configuration: `server.json`, mode `0600`
- Credential helper: `bin/codex-auth-newapi-credential`
- Service: `~/Library/LaunchAgents/com.codex-auth.newapi.plist`
- Management page: `http://127.0.0.1:3000`
- Codex API Base URL: `http://127.0.0.1:3000/v1`

NewAPI's official native server listens on port `3000` without a loopback-only binding option in this supported contract. Other devices on the same LAN may therefore reach the port when macOS firewall and network policy permit it. This workbench does not configure public Internet access, TLS, a domain, or a reverse proxy.

The SQLite database belongs to NewAPI and closes with the NewAPI process. There is no separate database service to stop. Upgrades preserve the database and the client Token; installer-owned runtime files are backed up before replacement.

## First Setup

1. Install the pinned NewAPI runtime with `install-newapi-runtime.sh <newapi-macos-binary>`.
2. In Codex Auth, open the routing page or settings and choose **Open NewAPI Management Page**. The app starts NewAPI before opening the page.
3. Complete NewAPI's native administrator setup.
4. Create a NewAPI Token in the native UI.
5. Paste that Token once into Codex Auth settings and save it.
6. Enable NewAPI from the menu bar.

When NewAPI is enabled, Codex Auth first requires CPA to be healthy, then stops NewAPI before touching its SQLite database. The channel configurator verifies the pinned runtime schema and creates or updates only the channel whose name and remark match the application-owned contract. The channel uses the CPA client Key from the protected CPA configuration, belongs to the `default` group, and synchronizes every non-empty model returned by the local CPA `/v1/models` endpoint into both `channels.models` and `abilities`. Model identifiers are de-duplicated and ordered deterministically, while `gpt-5.6-sol` remains the minimum model required by the managed health contract. A user-created channel is never adopted by matching its URL or Key. An unavailable or malformed CPA catalog, an unsafe identifier that NewAPI cannot represent, a missing required model, schema drift, or ambiguous application-owned rows fails closed before the Codex route changes.

The pinned NewAPI release scans `channels.channel_info` as JSON bytes rather than a plain SQLite text value. The managed-channel configurator therefore stores its empty channel metadata as a valid JSON BLOB; this keeps both the native channel page and the distributor's channel lookup compatible with the release schema.

### Upstream failure handling

The managed NewAPI contract enables bounded upstream failover. `RetryTimes` is set to `2`, so a failed request can try another credential or compatible channel without an unbounded retry loop. NewAPI automatically disables channels for `401`, `403`, `429`, and `500-599` responses, including balance and quota failures such as `403 insufficient balance`; its retry status list also covers the remaining recoverable `4xx` and `5xx` ranges supported by the pinned release. Channel affinity is released when an affiliated channel is disabled so the next attempt can be selected.

For a multi-key channel, NewAPI's native key selector is used first. If no usable key remains, routing proceeds to another enabled channel that supports the requested model and protocol. The managed configurator only controls its own reliability options and leaves user-created channels and unrelated options untouched. When every compatible candidate is disabled or exhausted, NewAPI returns the final error; the caller must then surface that the upstream is unavailable instead of repeatedly retrying the same failed channel.

Codex Auth never stores the NewAPI administrator password. The calling Token is stored only in protected `client.json`; `config.toml`, process arguments, registry JSON, and GUI JSON contain no Token value.

## Lifecycle

Enable order:

1. Start and validate CPA as the required managed upstream.
2. Stop NewAPI, synchronize the complete CPA model catalog into the application-owned channel, and restart NewAPI.
3. Validate NewAPI's status endpoint, administrator setup, credential helper, calling Token, and minimum managed model.
4. Patch Codex configuration to use `codex_auth_newapi` and persist `global_route = "newapi"`.

Disable and quit order:

1. Restore the selected direct connection.
2. Stop NewAPI, which also closes SQLite.
3. Stop the CPA gateway and any on-demand CPAMP management service.
4. Terminate Codex Auth only after shutdown succeeds.

If direct-route restoration fails, the app remains running and keeps the services alive so Codex is not left pointing at a stopped local endpoint. Close and quit actions require confirmation.

## Menu Modes

Direct mode keeps the account list and the Account, Manage, Statistics, Settings, and Quit actions. It exposes one NewAPI switch.

NewAPI mode hides direct-account operations and shows only NewAPI status, CPA upstream status, both native management-page actions, Disable, and Quit. The collapsed status item displays a readable NewAPI health state rather than a direct-account quota.
