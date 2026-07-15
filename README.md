# Codez

Codez is a minimal, upstream-compatible fork of the [OpenAI Codex CLI](https://github.com/openai/codex). It keeps Codex internals and local data formats intact while exposing the product as `codez`.

The first Codez release tracks upstream `rust-v0.144.4` and supports unsigned macOS Apple Silicon packages.

## Install

```shell
curl -fsSL https://github.com/streamsc/codez/releases/latest/download/install-codez.sh | sh
codez
```

The installer accepts the existing Codex environment controls:

- `CODEX_HOME` selects the shared configuration and session directory (default `~/.codex`).
- `CODEX_INSTALL_DIR` selects the public command directory (default `~/.local/bin`).
- `CODEX_RELEASE` pins a release such as `codez-v0.144.4-r1`.

## Codex compatibility and coexistence

Codez intentionally shares these Codex surfaces:

- `CODEX_HOME` and `.codex`
- authentication and keyring entries
- configuration, rollout sessions, memories, skills, plugins and SQLite state
- internal crates, protocols, model identity and `CODEX_*` environment variables

Coexistence-sensitive files are isolated:

- packages: `$CODEX_HOME/packages/codez/`
- update metadata: `$CODEX_HOME/codez/version.json`
- logs: `codez-tui.log` and `codez-login.log`
- app-server daemon socket, PID and lock directories use `codez-*` names

The main process is named `codez`. Code Mode may start a child named `codex-code-mode-host`; that helper keeps its upstream name and stays beside the real Codez binary inside the private Codez release directory. It is not linked into the public PATH, so an installed Codex helper is not overwritten.

## Development

The `main` branch is reserved for upstream tracking. Product changes live on the `codez` branch, which should be the repository default branch.

The internal Cargo binary target remains `codex`:

```shell
cd codex-rs
cargo build --bin codex --bin codex-code-mode-host
```

Build the Codez package layout by selecting the Codez package variant:

```shell
CODEZ_VERSION=0.144.4-r1 python3 scripts/build_codex_package.py \
  --variant codez \
  --target aarch64-apple-darwin \
  --cargo-profile release \
  --package-dir dist/codez-package \
  --archive-output dist/codez-package-aarch64-apple-darwin.tar.gz
```

Tags use `codez-v<upstream-version>-r<N>`, for example `codez-v0.144.4-r1`. The release workflow builds an unsigned macOS ARM64 archive and checksum. The scheduled upstream workflow detects stable `rust-vX.Y.Z` tags and opens a review PR without auto-merging.

## Upstream documentation

Codez keeps Codex configuration and behavior compatible, so the [Codex documentation](https://developers.openai.com/codex) remains the primary usage reference.

This repository is licensed under the [Apache-2.0 License](LICENSE).
