# Runtime Updates

Codex Switch checks the project-owned `runtime-update-manifest.json` at most once per day. The manifest is the compatibility boundary for NewAPI, CLIProxyAPI (CPA), and CPA Manager Plus (CPAMP); the app never follows an upstream `latest` URL.

An update is offered only when a newer project manifest contains complete HTTPS assets, a supported arm64 macOS target, and SHA-256 values. The user must confirm the upgrade. The updater downloads assets into a temporary directory, verifies every digest, stops managed services, preserves databases and user configuration, installs the complete compatibility set, and runs health checks. Any failure restores the previous installer-owned files and service state.

The current manifest records the versions already validated by this repository. A future release must update the manifest and installer compatibility contract together, then run the isolated installer and Swift test suites before publishing.
