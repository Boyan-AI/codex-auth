# Account, API Key, and CPA Optimization

This document defines the approved product and implementation direction for unifying ChatGPT accounts, API Key connections, and CPA smart routing.

## Product Positioning

Codex Auth manages one catalog of connections. A connection is either a ChatGPT account (`chatgpt`) or an API Key (`apikey`), including official and compatible relay providers.

CPA is a local smart-routing layer, not a third authentication type. Two states remain independent:

- Exactly one connection is current for newly launched direct sessions.
- Zero or more compatible connections may participate in CPA routing.

Changing either state must not implicitly change the other.

## User Workflows

### Direct Mode

**Set as Current** changes the connection used by the next direct Codex launch. Existing processes and sessions are not migrated.

Direct sessions remain bound to their originating connection. Normal resume uses that connection. Switching to another account, Key, or provider starts a new session; preserving local context across that boundary uses a fork.

Codex Auth can enforce this only for launches it initiates. Codex started outside the app follows the user's CLI configuration.

### Smart Routing

**Smart Launch Codex** always connects to the stable local CPA provider. CPA selects an eligible upstream, keeps session affinity where supported, and fails over when it becomes unavailable.

Accounts and Keys may coexist only in a compatibility group with the same wire protocol and compatible model mapping. Initial routing uses availability, cooldown, round-robin, and session affinity; it does not promise balance-aware optimization.

Smart launch never silently falls back to direct mode.

## Data and Balance Rules

The existing registry remains the single catalog. Extend its current records with optional provider metadata and balance snapshots, while keeping older registries readable.

- ChatGPT accounts display supported 5-hour and 7-day quota windows.
- API Keys never display ChatGPT time windows.
- API Keys display balance only after a successful provider response.
- Unsupported, failed, or empty responses produce no balance field or placeholder error.
- A previous value may survive a failed refresh only when visibly marked stale; otherwise it is hidden.

Official Keys default to the OpenAI endpoint. Relay Keys require an explicit HTTPS base URL. Provider adapters use short timeouts, cap response size, and parse structured JSON.

## CPA Synchronization

ChatGPT accounts continue to use the existing CPA OAuth export. API Key connections add CPA `codex-api-key` upstream entries without changing the active direct account file.

The desktop app synchronizes API Keys through CPA's localhost management endpoint
`/v0/management/codex-api-key`. The CLI performs a GET/PUT read-modify-write, preserves
existing CPA fields such as priority, weight, headers, and model restrictions, and strips
CPA's read-only `auth-index` before PUT. The CPA management key and upstream API Key are
never placed in CLI arguments, registry JSON, or normal command output.

- Enabling smart routing creates or updates only the selected connection's CPA entry.
- Disabling smart routing removes only that entry.
- Deleting a connection removes its CPA copy before catalog metadata.
- A synchronization failure preserves the user's selection and reports a recoverable warning.
- CPA client access keys remain separate from upstream model Keys.

## UI Specification

The app keeps the existing menu popover and three-column management window.

### Menu Popover

- Keep CPA status and **Smart Launch Codex** as the primary action.
- Change availability copy from "accounts" to "connections".
- Add a compact `All / Account / Key` filter beside sorting.
- Use a circular account icon and a square Key icon.
- Show quota only for accounts and balance only for Keys with successful data.
- Show current-direct and smart-pool state with compact icons.

### Connection Management

- Rename **Accounts** to **Connections** when Key support ships.
- Keep one unified list with type filters and search.
- Expose **Set as Current** and **Include in Smart Routing** as independent controls.
- Account actions use **Sign In Again**; Key actions use **Edit Key**.
- The add menu offers **ChatGPT Account** and **API Key**.

### Routing Page

- Keep CPA configuration and health on the existing Routing page.
- Pool rows include accounts and Keys with type, health, and applicable quota or balance.
- Show compatibility groups only when more than one group exists.

## Failure and Security Boundaries

- Switching the current direct connection affects only future launches.
- Smart-pool membership never changes the current direct connection.
- Existing Codex processes are never terminated during a switch.
- Relay addresses are validated before persistence.
- CPA runtime and management endpoints remain localhost-only.
- Session continuity means local history plus connection-bound resume, not shared cloud conversation state.
- Sensitive values must not appear in catalog output, GUI output, process arguments, or logs.

## Delivery Sequence

1. Extend the Zig registry and GUI contract with optional provider and balance metadata.
2. Add official and relay Key import, address validation, and balance adapters.
3. Add CPA API Key synchronization and compatibility validation.
4. Update macOS models, unified lists, detail controls, add/edit flows, and Routing page.
5. Test direct switching, CPA-only smart launch, data redaction, and balance omission.
6. Run Zig and Swift validation before desktop delivery.

## Acceptance Criteria

- Account and Key connections coexist in storage and the unified list.
- Exactly one connection is current for direct launches.
- Compatible connections independently join or leave CPA routing.
- Official and explicitly configured relay Keys work in direct and CPA modes.
- Quota and balance displays follow authentication type and omit unsupported data.
- Direct and CPA launch paths never silently replace each other.
- Sensitive values do not appear in machine-readable UI output, process arguments, or logs.
