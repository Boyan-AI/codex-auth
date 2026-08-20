# Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

# Validation

After modifying any `.zig` file, always run `zig build run -- list` to verify the changes work correctly.

# Execution Isolation

- Run tests, review commands, and other side-effecting tooling from an isolated directory under `/tmp/<task-name>` with `HOME=/tmp/<task-name>`.

# Desktop App Installation

- Use `macos/CodexAuthApp/scripts/install-desktop-app.sh` as the single entry point for compiling, overwriting, launching, and verifying the desktop app on the user's Desktop.
- When the user explicitly asks to install, reinstall, or overwrite the desktop app, that request authorizes the tool to quit the running desktop app, overwrite `~/Desktop/Codex Switch.app`, and relaunch it after normal code validation succeeds.
- When a completed desktop app change needs user verification but the user has not explicitly requested installation, explain that the running app will be quit and the Desktop copy overwritten, then wait for confirmation before running the tool.
- Run this tool with the real user `HOME`; this is a scoped exception to Execution Isolation because its target is the real Desktop. Build and test commands outside this installation workflow must remain isolated.
- Do not manually compose the build, quit, copy, launch, and process-check commands unless diagnosing a failure in the installation tool itself.

# Automated Desktop Delivery

- After a plan or code task is complete and its normal tests pass, create `.agent/desktop-delivery-ready.json` so the project `Stop` Hook can install, verify, commit, and push the result automatically.
- The marker must use schema version `1` and contain `base_commit` (the full current `HEAD`), `branch`, a Chinese `<type>: <description>` commit message, and an exact `paths` array containing only files owned by the task.
- Do not create the marker while implementation or validation is incomplete. Never include unrelated user changes in `paths`.
- The Hook must use `macos/CodexAuthApp/scripts/install-desktop-app.sh` as the only installation entry point. It must stop before commit or push if the worktree differs from the marker, installation fails, or single-process verification fails.
- If push fails after a successful commit, keep the marker's `committed_head` recovery state and retry only that exact commit after the external failure is resolved.
- Project Hook changes require one-time review through Codex `/hooks`; until trusted, invoke `.codex/hooks/desktop_delivery.py --manual` after creating the marker.

# Release Process

- When updating and pushing a release version, always follow [docs/release.md](./docs/release.md).

# Docs

- Do not add low-level technical implementation details to `README.md`. Put implementation-specific behavior in `docs/*.md` or `AGENTS.md` instead.

# Zig API Discovery

- Do not guess Zig APIs from memory or from examples targeting other Zig versions.
- Before using or changing a Zig API, run `zig env` and `zig version` to confirm the local toolchain and source layout.
- Use the paths reported by `zig env` as the source of truth, especially `std_dir` for the standard library and `lib_dir` for other bundled Zig libraries.
- Prefer evidence from local sources: symbol definitions, nearby tests, and existing call sites in this repository.
- If the needed behavior is not clear from `std_dir`, inspect other Zig sources and tests under the local `lib_dir` tree as needed.
