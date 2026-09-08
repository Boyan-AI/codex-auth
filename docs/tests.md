# Test Organization

This project keeps production modules behind normal module boundaries, while test files are compiled as separate test roots from `build.zig`.

## Goals

- Keep production code free of inline `test` blocks.
- Keep test-only fixtures outside `src/`.
- Run each test file as an independent Zig test artifact.
- Preserve the exact test descriptions from `main` when refactoring behavior.
- Prefer public behavior-oriented module boundaries over test-only access shims.

## Directory Layout

```text
src/
  root.zig              # public package surface
  ...                   # production modules only

tests/
  *_test.zig            # behavior and regression tests
  support/
    fixtures.zig        # test-only builders and file helpers
```

Test files should be grouped by product area or workflow, not by implementation detail. Use names such as `api_http_test.zig`, `registry_import_test.zig`, `tui_table_test.zig`, or `workflows_live_test.zig`.

## Build Integration

`build.zig` owns the test suite with an explicit `test_files` array. For each entry, it creates a separate `b.addTest` artifact and injects the `codex_auth` package import.

This keeps failures localized to the test file that owns them and avoids a large aggregate `tests/root.zig` importing everything manually.

A small library compile test may be included to validate the package surface with `std.testing.refAllDecls`.

## Production/Test Boundary

Production modules must not import `tests/` or `tests/support/`.

Avoid `test_api` or other test-only public namespaces in `src/`. If a rule is important enough to test directly, prefer one of these options:

1. Test it through a public behavior or workflow.
2. Extract it into a focused production module with a normal public API.
3. Make the helper public only when it is a stable, useful module boundary.

Private implementation details that are not stable behavior should not be tested directly.

## Fixtures

Fixtures belong under `tests/support/`. Import them with a relative path from tests:

```zig
const fixtures = @import("support/fixtures.zig");
```

Do not expose fixtures from `src/root.zig`.

## Test Descriptions

When refactoring, test descriptions must remain compatible with `main`. This is part of the compatibility contract. A refactor is acceptable only when the set of test descriptions remains unchanged unless the behavior itself intentionally changes.

## Validation Checklist

After changing `.zig` files, run these from an isolated `/tmp/<task-name>` directory with isolated `HOME` and `CODEX_HOME`:

```sh
zig fmt $(find /path/to/repo -name '*.zig' -type f | sort)
zig build --build-file /path/to/repo/build.zig --cache-dir /tmp/<task-name>/cache test
zig build --build-file /path/to/repo/build.zig --cache-dir /tmp/<task-name>/cache run -- list
git diff --check
```

Also verify:

```sh
rg '^test "' src
rg 'test_api|src/testing|testing\.fixtures' src tests
```

The first command should return no source inline tests. The second command should return no `test_api` or production fixture exports.

## Desktop App Validation

Run Swift validation with an isolated home and scratch directory:

```sh
HOME=/tmp/<task-name> swift test \
  --package-path /path/to/repo/macos/CodexAuthApp \
  --scratch-path /tmp/<task-name>/swift
```

The CPA global-routing suites cover schema 6 migration, route persistence, switching the fallback direct connection while CPA remains active, patch-preserving Codex configuration updates, command-backed client Key isolation, environment and macOS proxy rejection (including PAC and CGI environments), direct-only desktop URL sessions, credential-helper installation, service start/stop ordering, startup reconciliation and account-switch mutual exclusion, failure rollback, localhost-only runtime validation, pinned versions and panel assets, explicit Management Key copy, and system-browser management-page opening.

The registry suites also cover the cross-process stale-refresh regression: a usage snapshot saved after a newer NewAPI route write must preserve the persisted global route, and `clean` must retain `registry.json.lock`.

The NewAPI workbench suites cover schema 6 `newapi` compatibility and unknown-route fallback, dedicated provider replacement, Token isolation, fixed fork runtime installation, strict stamped-version and checksum validation, SQLite/client-config preservation, service/setup/Token status mapping, optional CPA degradation, enable/disable/quit ordering, failed direct-route restoration, first-setup management-page startup, and collapsed menu health presentation. Fork-level tests separately cover alias fingerprint persistence and selected-Key real-request isolation.

Validate the isolated CPA installer separately:

```sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/install-cpa-runtime.sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/cpa-credential-helper.sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/test-install-cpa-runtime.sh
HOME=/tmp/<task-name> /path/to/repo/macos/CodexAuthApp/scripts/test-install-cpa-runtime.sh
```

Validate the isolated NewAPI installer separately:

```sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/install-newapi-runtime.sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/newapi-credential-helper.sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/newapi-service-launcher.sh
bash -n /path/to/repo/macos/CodexAuthApp/scripts/test-install-newapi-runtime.sh
HOME=/tmp/<task-name> /path/to/repo/macos/CodexAuthApp/scripts/test-install-newapi-runtime.sh
```

`tests/token_usage_test.zig`
owns the full-to-incremental cache regression so production files remain free of
inline tests.
