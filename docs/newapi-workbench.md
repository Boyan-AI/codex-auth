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

The macOS Settings command (`Command-,`) and the menu-bar panel's Settings entry share the same NewAPI Token form and application state. The system Settings window presents that form directly; the menu-bar entry presents it inside the management window.

The managed NewAPI runtime is built from the Boyan-AI fork commit `c1fc71ee47eeb58921cd7e6815bbbb85dddd1f51`, which extends bounded recovery to every model and compatible upstream channel, propagates client cancellation, and preserves the Codex CLI-compatible AnyRouter channel-test contract. Its macOS arm64 asset reports `v1.0.0-codex-auth.6` and has SHA-256 `438a8f5a838f585c50bdfd5eb193c332b219dc369557f14fcf4b9aa6aed663d0`.

The installer requires both that exact version output and checksum before replacing any managed runtime file. The locally packaged macOS arm64 asset is `runtime/new-api-macos-v1.0.0-codex-auth.6`; it is a local build, and its remote asset URL remains empty until an explicitly approved release.

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

The fork applies bounded recovery to every model and compatible channel in the normal Relay path, not only CPA or `POST /v1/responses`. Temporary upstream `408`, `429`, and `5xx` errors qualify only when the native retry-status policy permits them; explicit skip-retry, channel-affinity restrictions, and single-attempt channel constraints still apply. There are at most five total attempts, including the initial request and native channel retries, even when cross-group selection resets its own retry index. Each retry keeps the original requested model and uses the existing priority, credential, and channel selector; it never silently changes models or switches Codex to a direct connection. Existing user-configured per-channel model mappings remain unchanged.

The recovery budget is 60 seconds from the first qualifying temporary failure. It covers both backoff and subsequent upstream requests; the initial attempt retains its normal timeout. Backoff uses equal jitter between half and all of the successive 2-, 4-, 8-, and 15-second caps. A valid upstream `Retry-After` (whole seconds or an HTTP date) is a waiting minimum. If it cannot fit into the remaining budget, the gateway returns the original failure immediately with the remaining `Retry-After` instead of retrying early or waiting pointlessly. A slow, uncommitted recovery request is canceled when the budget expires and returns HTTP `503` with `upstream recovery timed out after 60 seconds; model unchanged`. Client cancellation or an earlier client deadline stops recovery sooner.

Setting SSE headers or a status code alone is not a response commitment. Once headers are actually flushed or content is written, both ordinary retries and recovery stop. The recovery timer is released so a successfully recovered long stream is not cut off after one minute; client cancellation remains effective. A subsequent stream failure does not replay the request or append a separate JSON error to the partial stream. Recovery reuses the existing request and billing lifecycle and closes upstream bodies and cancellation callbacks on all normal and error paths. Requests with no compatible enabled channel, an unconfigured model, or permanent request/protocol configuration errors do not enter the recovery wait. Manual-disable state is not overridden.

The managed NewAPI contract enables bounded upstream failover. `RetryTimes` remains `2` for native non-transient retries and cross-group selection; the temporary-failure recovery above has its independent five-attempt ceiling. NewAPI automatically disables channels only for deterministic `401` and `403` failures, including balance and quota failures such as `403 insufficient balance`. A `400` model-compatibility failure (for example, a ChatGPT account that does not support the requested Codex model) is also eligible for native bounded retry, so NewAPI can continue to another credential or channel after CPA exhausts its own account candidates, without a recovery wait. Temporary `429`, network, and permitted `5xx` failures remain eligible for later requests, so a short upstream incident does not permanently quarantine a channel. The managed retry-status list retains its existing exclusions for `408`, `504`, and `524`; the fork does not override operator policy. Disabling retries disables temporary recovery as well. Channel affinity is released when an affiliated channel is disabled so the next attempt can be selected.

For a multi-key channel, NewAPI's native key selector is used first. If no usable key remains, routing proceeds to another enabled channel that supports the requested model and protocol. The managed configurator enables NewAPI's native passive recovery: automatic channel re-enable is on, background channel tests use concurrency 1, and `passive_recovery` probes only channels that NewAPI auto-disabled after real request failures. The recovery interval defaults to 10 minutes, can be adjusted in NewAPI's native settings from 1 to 1440 minutes, and is preserved by later Codex Auth channel synchronizations. A successful probe restores the channel without an external proxy or direct SQLite state manipulation. This background recovery is separate from request-scoped backoff: it uses a fixed interval, not per-status exponential backoff or a two-success circuit breaker. The managed configurator changes these global reliability options but does not modify user-created channel rows, Keys, models, or manual-disable state. When every compatible candidate is disabled or exhausted, or the request's recovery limit is reached, NewAPI returns the final error. A finite retry policy cannot make a permanently unavailable upstream usable.

The fork extends NewAPI's native multi-key dialog with per-Key aliases and a test action for one selected Key. Aliases are stored against a SHA-256 Key fingerprint so they remain attached after reordering and are removed with the Key. A test sends one real model request through only the selected Key: it disables selector fallback, does not mutate the channel, and does not persist the test model. The native page warns that the request may consume upstream quota and displays only duration and a sanitized success or failure result; neither Codex Auth nor the test response exposes the raw Key or full upstream response.

Codex Auth never stores the NewAPI administrator password. The calling Token is stored only in protected `client.json`; `config.toml`, process arguments, registry JSON, and GUI JSON contain no Token value.

## Live Request Verification

On 2026-10-22, the installed `v1.0.0-codex-auth.6` runtime with the checksum above passed one real streaming `POST /v1/responses` request using the saved client Token and normal channel selection. The requested model was `gpt-6.1-sol`, and the only input was `Reply with exactly OK.`. The response returned HTTP `200`, emitted `response.completed` with status `completed`, and produced `OK` in 3.495 seconds. Usage was 11 input Tokens and 38 output Tokens, including 31 reasoning Tokens; NewAPI recorded a charge of `$0.006526`.

The native consume log matched request ID `202610221303024425370008268d9d65Zn5tkMI` to channel `2` (AgentRouter), group `default`, and stream status `ok`. Channel enablement and the user's direct route were preserved, and the temporary verification service was stopped afterward. This verifies one successful request through the installed runtime, not sustained upstream availability or recovery after an actual outage. The five-attempt limit, 60-second recovery budget, cancellation, and response-commit boundaries are covered separately by deterministic regression tests; no upstream outage was induced for this check.

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

The connected state confirms that the local NewAPI service is running, setup is complete, and the saved Token can read a structurally valid `/v1/models` response. It does not require any specific model identifier: a catalog containing only `gpt-6-astra`, or an empty catalog, does not make the service unavailable. Model and channel availability remain NewAPI routing concerns, so connected does not guarantee that a particular model request will succeed. HTTP 401/403 still report an invalid Token; network failures, other unsuccessful HTTP responses, and malformed model catalogs still report the service as unavailable.
