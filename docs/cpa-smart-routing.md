# CPA Global Service Routing

This document defines the product boundary between the official Codex CLI, Codex Auth, and CLIProxyAPI (CPA).

## Product Boundary

- The official Codex CLI remains the terminal client. Codex Auth does not wrap or launch a special `codex` process for CPA.
- The desktop app owns the CPA user service lifecycle and the provider selected in the shared Codex configuration.
- When CPA is enabled, newly started Codex processes or threads use the stable local `codex_auth_cpa` provider, including `codex` started directly from a terminal.
- When CPA is disabled, newly started Codex processes or threads use the currently selected direct ChatGPT account or API Key connection.
- Running Codex processes do not hot-reload this route. Explicit Codex `--config/-c` overrides may still override the user-level provider for one invocation.

- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Codex CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)

## Ownership and Isolation

Codex Auth and CPA have separate account and Key stores.

- Codex Auth owns direct ChatGPT/API Key snapshots, aliases, quota data, and the direct connection selected for use after CPA is disabled.
- CPA owns its OAuth sessions, upstream Keys, providers, quotas, and routing policy. These are managed only through CPA's native management page.
- Codex Auth never copies, synchronizes, disables, deletes, or reconciles CPA account data.
- Selecting a Codex Auth connection while CPA is enabled updates `auth.json`, registry state, and the fallback direct connection. It does not replace the active CPA provider.

Registry schema 6 stores one root-level `global_route` value: `direct`, legacy `cpa`, or `newapi`. Per-account smart-pool membership no longer exists. Registries from schema 5 or earlier migrate to `direct`; legacy smart-pool fields are ignored and omitted on the next save. The desktop product now uses NewAPI as the unified route and keeps CPA routing commands only for compatibility; see [NewAPI Local Workbench](./newapi-workbench.md).

## Global Codex Configuration

Codex Auth patches only its managed provider settings in `<codex_home>/config.toml` and preserves unrelated tables, comments, unknown keys, and file permissions.

- CPA uses `model_provider = "codex_auth_cpa"` with `http://127.0.0.1:8317/v1`.
- Provider authentication is command-backed. The installed CPA credential helper reads the client Key from the protected `client.json` file only after confirming that the local request cannot be sent to a non-loopback proxy.
- The client Key is not stored in `config.toml`, command arguments, registry JSON, or GUI JSON.
- Disabling CPA restores the direct preset for the latest selected ChatGPT account or API Key. If there is no selected connection, Codex Auth restores the default direct provider settings.

### Terminal Proxy Compatibility

The Codex HTTP client can inherit `HTTP_PROXY`, `ALL_PROXY`, and macOS system proxy settings. When Codex's `respect_system_proxy` feature is enabled, CFNetwork system and PAC routing takes precedence over environment proxy exclusions. The credential helper therefore validates the environment and macOS system paths independently before returning the client Key.

The desktop app's own CPA health and Management API requests use a dedicated ephemeral `URLSession` that explicitly disables HTTP, HTTPS, SOCKS, PAC, and proxy auto-discovery. Client and Management Keys are therefore sent directly to the validated loopback endpoint rather than through the user's system proxy. This does not change proxy behavior for separately launched `codex` processes, which remains guarded by the credential helper.

CPA routing works without extra configuration when the macOS system route is direct or uses a loopback manual proxy. Automatic PAC or proxy-discovery routes cannot be proven safe by the credential helper and fail closed. A non-loopback terminal proxy additionally requires the CPA host in the exclusion variables before starting Codex; `NO_PROXY` takes precedence when both forms are present:

```sh
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}127.0.0.1,localhost"
export no_proxy="${no_proxy:+$no_proxy,}127.0.0.1,localhost"
```

`NO_PROXY` only excludes environment proxies; it does not override a non-loopback macOS system or PAC route. Codex Auth does not modify shell startup files, Codex feature flags, or system proxy settings.

## Runtime Contract

The managed runtime is pinned to CLIProxyAPI `7.2.120` and management panel `v1.21.4`. The installer contains and verifies the expected SHA-256 for both assets before writing the runtime.

- Runtime root: `~/Library/Application Support/Codex Auth/CPA`
- CPA configuration: `config.yaml`, mode `0600`
- App client configuration: `client.json`, mode `0600`
- CPA credential helper: `bin/codex-auth-cpa-credential`
- Installed management page: `static/management.html`
- CPA-owned accounts and providers: under the runtime root, separate from `~/.codex`
- Service: `~/Library/LaunchAgents/com.codex-auth.cpa.plist`

The installer creates a localhost-only default configuration and installs the service disabled on first install. Upgrades preserve whether the service was running and do not replace user-owned CPA account, provider, quota, or routing configuration. The known `7.2.109` installer contract and old LaunchAgent label are migrated narrowly.

The app validates the installed contract before selecting the global CPA provider:

- the proxy listens on `127.0.0.1:8317` and remote management is disabled;
- the authenticated Management API reports CPA `7.2.120` and contains the installed client Key;
- the raw authenticated configuration uses the supported localhost and panel safety fields;
- the served `management.html` matches the pinned panel SHA-256;
- the command authentication helper is installed and executable;
- panel auto-update is disabled, so first use does not fetch an unpinned frontend.

The validation parser accepts only the installer-owned YAML representation. Unsupported or ambiguous forms fail closed and are reported as incompatible; the app does not overwrite the user's CPA configuration to make it pass. A valid empty `/v1/models` array is accepted so a new installation can open the panel before its first upstream account is added.

## Service Lifecycle

CPA is a user-level LaunchAgent. In the NewAPI workbench, quitting Codex Auth restores direct routing and stops both NewAPI and CPA. Legacy CPA-only lifecycle behavior below remains documented for compatibility.

Enable order:

1. Enable and start the LaunchAgent.
2. Validate the fixed loopback address, Management API configuration, runtime version, client Key registration, credential helper, and panel asset.
3. Send the client Key only to the validated loopback model endpoint and verify health.
4. Select the global CPA provider.

If any enable step fails, the app restores direct routing and attempts to stop and disable CPA. Disable order is intentionally reversed: restore direct routing first, then stop and disable the service. This prevents newly started Codex processes from pointing at an unavailable local endpoint.

On app launch, the persisted `global_route` is reconciled with launchd and the installed runtime. A persisted CPA route that cannot be made healthy is downgraded to direct mode with a visible error.

## Management Page

The native panel opens in the system browser at `http://127.0.0.1:8317/management.html` only after the service and runtime contract are healthy. The Management Key is never placed in the URL. The menu and routing page expose a separate explicit copy action so the user can authenticate in the panel.

Codex Auth installs CPA Manager Plus `1.11.11-codex-auth.1`, based on upstream `v1.11.11`, from the dedicated fork tag [`codex-auth-ui-v1.11.11.1`](https://github.com/Boyan-AI/CPA-Manager-Plus/releases/tag/codex-auth-ui-v1.11.11.1). The installer pins the versioned Darwin arm64 asset and verifies SHA-256 `b84b6f92819a097b0b3e25a351440a87f239854264b3c06f9fce6c222a315795` before replacing the managed binary.

This CPAMP build changes only log presentation:

- the filter and action area does not have an independent vertical scrollbar;
- log rows show concise status, time, semantic summary, and duration by default;
- complete methods, paths, client addresses, source locations, request IDs, and raw-log actions remain available in expanded details;
- management traffic is hidden by default with a visible buffered-entry count and can be shown temporarily;
- a management request failure is identified separately and does not imply that a model request failed.

These presentation rules do not change CPA routing, proxy or TUN behavior, upstream requests, status codes, or raw log content.

CPA's primary repository documents its configuration and management API:

- [CLIProxyAPI example configuration](https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml)
- [CLIProxyAPI management API](https://github.com/router-for-me/CLIProxyAPI/blob/main/MANAGEMENT_API.md)

CPA is a third-party dependency. Codex Auth validates the pinned version and supported endpoints instead of assuming releases are interchangeable.

## Interface Contract

- The menu and routing page expose one global CPA toggle, service status, the fixed service address, Management Key copy, and native management-page actions.
- Account rows remain direct-connection controls. While CPA is enabled, the selected row is labeled as the connection used after CPA is disabled.
- Startup reconciliation, CPA lifecycle changes, and fallback-account switching are mutually exclusive so stale asynchronous results cannot reverse the final route or stop a service still referenced by Codex.
- The app does not display CPA accounts, upstream Keys, pool membership, or request events.
- Service states distinguish not installed, stopped, starting, running, unavailable, and incompatible.
