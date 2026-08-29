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

The managed NewAPI runtime is pinned to the Boyan-AI fork release [`codex-auth-v1.0.0.1`](https://github.com/Boyan-AI/new-api/releases/tag/codex-auth-v1.0.0.1). Its macOS arm64 asset reports `v1.0.0-codex-auth.1` and has SHA-256 `e8d473931c71532aeb135cf0d5e958c67e5041ee539bd8bef92d0cd2ab0eec6b`.

The installer requires both that exact version output and checksum before replacing any managed runtime file. The release asset is available at `https://github.com/Boyan-AI/new-api/releases/download/codex-auth-v1.0.0.1/new-api-macos-v1.0.0-codex-auth.1`; `checksums-macos.txt` is published beside it.

- Runtime root: `~/Library/Application Support/Codex Auth/NewAPI`
- SQLite database: `data/new-api.db`
- Client configuration: `client.json`, mode `0600`
- Server configuration: `server.json`, mode `0600`
- Credential helper: `bin/codex-auth-newapi-credential`
- Service: `~/Library/LaunchAgents/com.codex-auth.newapi.plist`
- Management page: `http://127.0.0.1:3000`
- Codex API Base URL: `http://127.0.0.1:3000/v1`

NewAPI's native server listens on port `3000` without a loopback-only binding option in this supported contract. Other devices on the same LAN may therefore reach the port when macOS firewall and network policy permit it. This workbench does not configure public Internet access, TLS, a domain, or a reverse proxy.

The SQLite database belongs to NewAPI and closes with the NewAPI process. There is no separate database service to stop. Upgrades preserve the database and the client Token; installer-owned runtime files are backed up before replacement.

## First Setup

1. Install the pinned NewAPI runtime with `install-newapi-runtime.sh <newapi-macos-binary>`.
2. In Codex Auth, open the routing page or settings and choose **Open NewAPI Management Page**. The app starts NewAPI before opening the page.
3. Complete NewAPI's native administrator setup.
4. Create a NewAPI Token in the native UI.
5. Paste that Token once into Codex Auth settings and save it.
6. Enable NewAPI from the menu bar.

When NewAPI is enabled, Codex Auth starts NewAPI independently and treats CPA as one optional managed channel. It attempts to start CPA and synchronize the channel, but CPA account, model, Token, or network availability never blocks the NewAPI route change. The channel configurator verifies the pinned runtime schema and creates or updates only the channel whose name and remark match the application-owned contract. The channel uses the CPA client Key from the protected CPA configuration, belongs to the `default` group, and synchronizes every non-empty model returned by the local CPA `/v1/models` endpoint into both `channels.models` and `abilities`. Model identifiers are de-duplicated and ordered deterministically. A valid CPA catalog may omit `gpt-5.6-sol` (or be empty); in that case the managed channel declares only its reported capabilities, allowing NewAPI to select another compatible channel. If CPA is unavailable, the existing managed channel is preserved when possible and the route still switches to NewAPI; the next channel synchronization can repair it. A user-created channel is never adopted by matching its URL or Key. Static safety failures such as an unsafe identifier, schema drift, or ambiguous application-owned rows are reported as channel-sync failures and do not stop NewAPI itself; NewAPI runtime or route-write failures still fail closed.

The pinned NewAPI release scans `channels.channel_info` as JSON bytes rather than a plain SQLite text value. The managed-channel configurator therefore stores its empty channel metadata as a valid JSON BLOB; this keeps both the native channel page and the distributor's channel lookup compatible with the release schema.

### Upstream failure handling

The managed NewAPI contract enables bounded upstream failover. `RetryTimes` is set to `2`, so a failed request can try another credential or compatible channel without an unbounded retry loop. NewAPI automatically disables channels only for deterministic `401` and `403` failures, including balance and quota failures such as `403 insufficient balance`. A `400` model-compatibility failure (for example, a ChatGPT account that does not support the requested Codex model) is also eligible for the bounded retry status list, so NewAPI can continue to another credential or channel after CPA exhausts its own account candidates. Temporary `429`, network, and `5xx` failures remain eligible for later requests and are handled by the bounded retry status list, so a short upstream incident does not permanently quarantine a channel. Channel affinity is released when an affiliated channel is disabled so the next attempt can be selected.

For a multi-key channel, NewAPI's native key selector is used first. If no usable key remains, routing proceeds to another enabled channel that supports the requested model and protocol. The managed configurator enables NewAPI's native passive recovery: automatic channel re-enable is on, background channel tests use concurrency 1, and `passive_recovery` probes only channels that NewAPI auto-disabled after real request failures. The recovery interval defaults to 10 minutes, can be adjusted in NewAPI's native settings from 1 to 1440 minutes, and is preserved by later Codex Auth channel synchronizations. A successful probe restores the channel without an external proxy or direct SQLite state manipulation. This is a fixed-interval native recovery policy, not per-status exponential backoff or a two-success circuit breaker. The managed configurator changes these global reliability options but does not modify user-created channel rows, Keys, models, or manual-disable state. When every compatible candidate is disabled or exhausted, NewAPI returns the final error; the caller must then surface that the upstream is unavailable instead of repeatedly retrying the same failed channel.

The fork extends NewAPI's native multi-key dialog with per-Key aliases and a test action for one selected Key. Aliases are stored against a SHA-256 Key fingerprint so they remain attached after reordering and are removed with the Key. A test sends one real model request through only the selected Key: it disables selector fallback, does not mutate the channel, and does not persist the test model. The native page warns that the request may consume upstream quota and displays only duration and a sanitized success or failure result; neither Codex Auth nor the test response exposes the raw Key or full upstream response.

Codex Auth never stores the NewAPI administrator password. The calling Token is stored only in protected `client.json`; `config.toml`, process arguments, registry JSON, and GUI JSON contain no Token value.

## Lifecycle

Enable order:

1. Start CPA on a best-effort basis as the optional managed upstream.
2. Stop NewAPI and attempt to synchronize the application-owned CPA channel; an unavailable CPA only skips this attempt.
3. Start NewAPI and apply the `codex_auth_newapi` provider route without waiting for CPA, Token, or model health.
4. Persist `global_route = "newapi"`; health and channel recovery are reported asynchronously.

Disable and quit order:

1. Restore the selected direct connection.
2. Stop NewAPI, which also closes SQLite.
3. Stop the CPA gateway and any on-demand CPAMP management service.
4. Terminate Codex Auth only after shutdown succeeds.

If direct-route restoration fails, the app remains running and keeps the services alive so Codex is not left pointing at a stopped local endpoint. Close and quit actions require confirmation.

## Menu Modes

Direct mode keeps the account list and the Account, Manage, Statistics, Settings, and Quit actions. It exposes one NewAPI switch.

NewAPI mode hides direct-account operations and shows only NewAPI status, CPA upstream status, both native management-page actions, Disable, and Quit. The collapsed status item displays a readable NewAPI health state rather than a direct-account quota.
