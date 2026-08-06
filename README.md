# Codez

[English](README.md) | [Simplified Chinese](README.zh-CN.md)

Codez is a minimal, upstream-compatible fork of the [OpenAI Codex CLI](https://github.com/openai/codex). It keeps Codex internals and local data formats intact while exposing the product as `codez`.

Codez tracks upstream Codex releases and publishes unsigned packages for macOS Apple Silicon and Linux x86_64/ARM64.

## Install

```shell
curl -fsSL https://github.com/streamsc/codez/releases/latest/download/install-codez.sh | sh
codez
```

The installer detects the current platform and downloads one of these release packages:

- `codez-package-aarch64-apple-darwin.tar.gz`
- `codez-package-x86_64-unknown-linux-musl.tar.gz`
- `codez-package-aarch64-unknown-linux-musl.tar.gz`

The installer accepts the existing Codex environment controls:

- `CODEX_HOME` selects the shared configuration and session directory (default `~/.codex`).
- `CODEX_INSTALL_DIR` selects the public command directory (default `~/.local/bin`).
- `CODEX_RELEASE` pins a release such as `codez-v0.146.1-r1`.

### Offline install

Each Codez release also publishes a multi-platform offline bundle. Copy
`codez-offline-vX.Y.Z-rN.tar.gz` and `codez-offline-bundle_SHA256SUMS` to the
offline machine, verify the outer bundle checksum, and extract the bundle:

```shell
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c codez-offline-bundle_SHA256SUMS
else
  shasum -a 256 -c codez-offline-bundle_SHA256SUMS
fi
tar -xzf codez-offline-v0.146.1-r1.tar.gz
./codez-offline-v0.146.1-r1/install-codez-offline.sh \
  --bundle ./codez-offline-v0.146.1-r1
```

The offline installer selects the matching macOS Apple Silicon, Linux x86_64,
or Linux ARM64 package, verifies its bundled SHA-256 entry, and installs it
without contacting GitHub. It accepts the same `CODEX_HOME` and
`CODEX_INSTALL_DIR` environment variables as the online installer.

To configure the installed Codez for an internal OpenAI-compatible Responses
API and skip the first-run login screen, provide the full API root and API key:

```shell
./codez-offline-v0.146.1-r1/install-codez-offline.sh \
  --bundle ./codez-offline-v0.146.1-r1 \
  --api-base-url https://gateway.internal/v1 \
  --api-key sk-internal \
  --model internal-model
```

`--model` is optional. The installer validates the URL without contacting the
service, preserves unrelated settings in `CODEX_HOME/config.toml`, and stores
the API key through Codez's normal API-key login flow rather than in
`config.toml`. The service must expose the Responses API at
`{api-base-url}/responses`; a Chat Completions-only gateway is not sufficient.
HTTP endpoints are accepted with a warning because the API key will be sent
without transport encryption.

On success, Codez writes the endpoint to `openai_base_url`, selects the built-in
`openai` provider, and writes `model` only when `--model` is supplied. Existing
model reasoning settings and unrelated TOML entries remain intact. Credential
storage follows `cli_auth_credentials_store`, so the same authentication is
available to Codex when both products share `CODEX_HOME`.

Passing `--api-key` can expose the secret in shell history and process listings.
The installer does not echo it or forward it in the child Codez command line.
Because Codez and Codex share `CODEX_HOME`, this configuration is also visible
to Codex when both products use the same home directory.

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
CODEZ_VERSION=0.146.1-r1 python3 scripts/build_codex_package.py \
  --variant codez \
  --target aarch64-apple-darwin \
  --cargo-profile release \
  --package-dir dist/codez-package \
  --archive-output dist/codez-package-aarch64-apple-darwin.tar.gz
```

Linux releases use musl and include a bundled `bwrap`. Build `bwrap` first, finalize its bytes, and pass its digest into the Codez build:

```shell
TARGET=x86_64-unknown-linux-musl
cd codex-rs
cargo build --target "$TARGET" --release --bin bwrap
strip --strip-debug --strip-unneeded "target/$TARGET/release/bwrap"
export CODEX_BWRAP_SHA256="$(sha256sum "target/$TARGET/release/bwrap" | awk '{print $1}')"
cd ..
CODEZ_VERSION=0.146.1-r1 python3 scripts/build_codex_package.py \
  --variant codez \
  --target "$TARGET" \
  --cargo-profile release \
  --bwrap-bin "codex-rs/target/$TARGET/release/bwrap" \
  --package-dir "dist/codez-package-$TARGET" \
  --archive-output "dist/codez-package-$TARGET.tar.gz"
```

Tags use `codez-v<upstream-version>-r<N>`, for example `codez-v0.146.1-r1`. The release workflow builds all three platform archives, publishes one checksum manifest, and caches Cargo dependencies and compiler outputs between runs. The scheduled upstream workflow detects stable `rust-vX.Y.Z` tags and opens a review PR without auto-merging.

## Upstream documentation

Codez keeps Codex configuration and behavior compatible, so the [Codex documentation](https://developers.openai.com/codex) remains the primary usage reference.

This repository is licensed under the [Apache-2.0 License](LICENSE).
