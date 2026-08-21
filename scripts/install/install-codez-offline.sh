#!/bin/sh

set -eu

INSTALL_ROOT=""
RELEASES_DIR=""
CURRENT_LINK=""
LOCK_DIR=""
BIN_DIR=""
BIN_PATH=""
tmp_dir=""
stage_dir=""
release_dir=""
rollback_dir=""
lock_acquired=false
rollback_active=false
api_config_requested=false
api_base_url=""
api_key=""
model=""
xtrace_was_enabled=false

case "$-" in
  *x*)
    xtrace_was_enabled=true
    set +x
    ;;
esac

usage() {
  cat <<'EOF'
Usage: install-codez-offline.sh --bundle PATH [API OPTIONS]

Installs Codez from a local offline bundle directory or .tar.gz archive.

API options:
  --api-base-url URL  Full OpenAI-compatible API root, such as https://host/v1.
  --api-key KEY       API key to store using Codez's configured credential store.
  --model MODEL       Optional default model for new sessions.

--api-base-url and --api-key must be provided together. Supplying --api-key can
expose the key in shell history and process listings. The installer never passes
the key to child processes as a command-line argument.

Environment:
  CODEX_INSTALL_DIR  Directory for the public codez symlink (default: ~/.local/bin).
  CODEX_HOME         Shared Codex/Codez home directory (default: ~/.codex).
EOF
}

cleanup() {
  set +e
  if [ "$rollback_active" = true ]; then
    rollback_install
  fi
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    rm -rf "$stage_dir"
  fi
  if [ "$lock_acquired" = true ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ -n "$rollback_dir" ] && [ -d "$rollback_dir" ]; then
    rm -rf "$rollback_dir"
  fi
}

trap cleanup EXIT HUP INT TERM

fail() {
  echo "Offline Codez installation failed: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

snapshot_path() {
  path="$1"
  name="$2"
  if [ -L "$path" ]; then
    readlink "$path" >"$rollback_dir/$name.symlink"
  elif [ -f "$path" ]; then
    cp -p "$path" "$rollback_dir/$name.file"
  elif [ -e "$path" ]; then
    fail "Cannot safely snapshot existing path: $path"
  else
    : >"$rollback_dir/$name.absent"
  fi
}

restore_path() {
  path="$1"
  name="$2"
  rm -f "$path"
  if [ -f "$rollback_dir/$name.symlink" ]; then
    mkdir -p "$(dirname "$path")"
    ln -s "$(cat "$rollback_dir/$name.symlink")" "$path"
  elif [ -f "$rollback_dir/$name.file" ]; then
    mkdir -p "$(dirname "$path")"
    cp -p "$rollback_dir/$name.file" "$path"
  fi
}

prepare_rollback() {
  rollback_dir="$(mktemp -d "$INSTALL_ROOT/.rollback.XXXXXX")"
  chmod 0700 "$rollback_dir"
  snapshot_path "$CURRENT_LINK" current
  snapshot_path "$BIN_PATH" public-bin
  snapshot_path "$CODEX_HOME_DIR/config.toml" config
  snapshot_path "$CODEX_HOME_DIR/auth.json" auth
  rollback_active=true
}

rollback_install() {
  if [ -n "$release_dir" ]; then
    rm -rf "$release_dir"
    if [ -d "$rollback_dir/release-dir" ]; then
      mv "$rollback_dir/release-dir" "$release_dir"
    fi
  fi
  restore_path "$CURRENT_LINK" current
  restore_path "$BIN_PATH" public-bin
  restore_path "$CODEX_HOME_DIR/config.toml" config
  restore_path "$CODEX_HOME_DIR/auth.json" auth
  rollback_active=false
}

commit_install() {
  rollback_active=false
  rm -rf "$rollback_dir"
  rollback_dir=""
}

sha256_verify() {
  checksum_line="$1"
  checksum_dir="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$checksum_dir" && printf '%s\n' "$checksum_line" | sha256sum -c -)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$checksum_dir" && printf '%s\n' "$checksum_line" | shasum -a 256 -c -)
  else
    fail "sha256sum or shasum is required."
  fi
}

manifest_value() {
  key="$1"
  manifest="$2"
  value_count="$(awk -F= -v wanted="$key" '$1 == wanted {count++} END {print count + 0}' "$manifest")"
  [ "$value_count" -eq 1 ] || fail "Manifest must contain exactly one $key entry."
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$manifest"
}

validate_format_version() {
  [ "$1" = 1 ] || fail "Unsupported offline bundle format version: $1"
}

validate_release_tag() {
  tag="$1"
  printf '%s\n' "$tag" | grep -Eq '^codez-v[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$' \
    || fail "Invalid releaseTag in manifest: $tag"
}

validate_extracted_tree() {
  root="$1"
  if find "$root" -type l -print -quit | grep -q .; then
    fail "Offline bundle must not contain symbolic links."
  fi
}

extract_bundle() {
  bundle="$1"
  case "$bundle" in
    *.tar.gz|*.tgz)
      [ -f "$bundle" ] || fail "Bundle archive does not exist: $bundle"
      tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codez-offline.XXXXXX")"
      archive_listing="$(tar -tzf "$bundle")" || fail "Cannot read bundle archive: $bundle"
      printf '%s\n' "$archive_listing" | awk '
        /^\// || /(^|\/)\.\.($|\/)/ {bad=1}
        END {exit bad}
      ' || fail "Bundle archive contains an unsafe path."
      tar -xzf "$bundle" -C "$tmp_dir" || fail "Cannot extract bundle archive."
      set -- "$tmp_dir"/*
      if [ "$#" -eq 1 ] && [ -d "$1" ]; then
        BUNDLE_ROOT="$1"
      else
        BUNDLE_ROOT="$tmp_dir"
      fi
      ;;
    *)
      [ -d "$bundle" ] || fail "Bundle must be a directory or .tar.gz archive: $bundle"
      BUNDLE_ROOT="$bundle"
      ;;
  esac
  BUNDLE_ROOT="$(CDPATH= cd -- "$BUNDLE_ROOT" && pwd)"
  validate_extracted_tree "$BUNDLE_ROOT"
}

detect_target() {
  system="$(uname -s)"
  machine="$(uname -m)"
  case "$system:$machine" in
    Darwin:arm64|Darwin:aarch64) TARGET=aarch64-apple-darwin ;;
    Darwin:x86_64) TARGET=x86_64-apple-darwin ;;
    Linux:x86_64|Linux:amd64) TARGET=x86_64-unknown-linux-musl ;;
    Linux:arm64|Linux:aarch64) TARGET=aarch64-unknown-linux-musl ;;
    Darwin:*) fail "Codez offline releases support x86_64 and ARM64 macOS only; detected $machine." ;;
    Linux:*) fail "Codez offline releases support x86_64 and ARM64 Linux only; detected $machine." ;;
    *) fail "Codez offline releases support macOS and Linux only; detected $system/$machine." ;;
  esac
}

install_from_bundle() {
  manifest="$BUNDLE_ROOT/codez-offline-manifest"
  checksums="$BUNDLE_ROOT/codez-package_SHA256SUMS"
  [ -f "$manifest" ] || fail "Bundle is missing codez-offline-manifest."
  [ -f "$checksums" ] || fail "Bundle is missing codez-package_SHA256SUMS."

  format_version="$(manifest_value formatVersion "$manifest")"
  release_tag="$(manifest_value releaseTag "$manifest")"
  validate_format_version "$format_version"
  validate_release_tag "$release_tag"

  target_key="asset.$TARGET"
  asset="$(manifest_value "$target_key" "$manifest")"
  expected_asset="codez-package-$TARGET.tar.gz"
  [ "$asset" = "$expected_asset" ] || fail "Manifest maps $TARGET to unexpected asset: $asset"
  case "$asset" in
    */*|*..*) fail "Manifest contains an unsafe archive name: $asset" ;;
  esac
  archive_path="$BUNDLE_ROOT/$asset"
  [ -f "$archive_path" ] || fail "Bundle is missing $asset."

  checksum_line="$(grep -E "^[0-9a-fA-F]{64}  $asset$" "$checksums" | head -n 1 || true)"
  [ -n "$checksum_line" ] || fail "Checksum manifest does not contain $asset."
  sha256_verify "$checksum_line" "$BUNDLE_ROOT" || fail "Checksum verification failed for $asset."

  stage_dir="$RELEASES_DIR/.staging.$$"
  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  tar -xzf "$archive_path" -C "$stage_dir" || fail "Cannot extract $asset."
  validate_extracted_tree "$stage_dir"

  for required in bin/codez bin/codex-code-mode-host codex-path/rg codex-package.json; do
    [ -f "$stage_dir/$required" ] || fail "Release archive is missing $required."
  done
  if [ "$system" = Linux ]; then
    [ -f "$stage_dir/codex-resources/bwrap" ] || fail "Linux release archive is missing codex-resources/bwrap."
  fi

  package_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$stage_dir/codex-package.json" | head -n 1)"
  package_variant="$(sed -n 's/.*"variant"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$stage_dir/codex-package.json" | head -n 1)"
  release_version="${release_tag#codez-v}"
  upstream_version="${release_version%-r*}"
  [ "$package_variant" = codez ] || fail "Release archive is not a Codez package."
  [ "$package_version" = "$upstream_version" ] \
    || fail "Package metadata version does not match manifest upstream version."
  chmod 0755 "$stage_dir/bin/codez" "$stage_dir/bin/codex-code-mode-host" "$stage_dir/codex-path/rg"
  if [ "$system" = Linux ]; then chmod 0755 "$stage_dir/codex-resources/bwrap"; fi
  reported_version="$("$stage_dir/bin/codez" --version)"
  [ "$reported_version" = "codez $release_version" ] \
    || fail "Packaged Codez binary did not report the expected version."

  release_dir="$RELEASES_DIR/${release_tag#codez-v}-$TARGET"
  if [ "$rollback_active" = true ] && [ -e "$release_dir" ]; then
    mv "$release_dir" "$rollback_dir/release-dir"
  else
    rm -rf "$release_dir"
  fi
  mv "$stage_dir" "$release_dir"
  stage_dir=""

  tmp_current="$INSTALL_ROOT/.current.$$"
  ln -s "$release_dir" "$tmp_current"
  rm -f "$CURRENT_LINK"
  mv "$tmp_current" "$CURRENT_LINK"

  tmp_bin="$BIN_DIR/.codez.$$"
  ln -s "$CURRENT_LINK/bin/codez" "$tmp_bin"
  rm -f "$BIN_PATH"
  mv "$tmp_bin" "$BIN_PATH"
}

bundle_path=""
bundle_seen=false
api_base_url_seen=false
api_key_seen=false
model_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      [ "$bundle_seen" = false ] || fail "--bundle may only be specified once."
      bundle_path="$2"
      bundle_seen=true
      shift 2
      ;;
    --api-base-url)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      [ "$api_base_url_seen" = false ] || fail "--api-base-url may only be specified once."
      api_base_url="$2"
      api_base_url_seen=true
      shift 2
      ;;
    --api-key)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      [ "$api_key_seen" = false ] || fail "--api-key may only be specified once."
      api_key="$2"
      api_key_seen=true
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      [ "$model_seen" = false ] || fail "--model may only be specified once."
      model="$2"
      model_seen=true
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done
[ -n "$bundle_path" ] || { usage >&2; exit 1; }

if [ "$api_base_url_seen" = true ] || [ "$api_key_seen" = true ] || [ "$model_seen" = true ]; then
  [ "$api_base_url_seen" = true ] || fail "--api-base-url is required when configuring an API."
  [ "$api_key_seen" = true ] || fail "--api-key is required when configuring an API."
  [ -n "$api_base_url" ] || fail "--api-base-url must not be empty."
  [ -n "$api_key" ] || fail "--api-key must not be empty."
  if [ "$model_seen" = true ]; then
    [ -n "$model" ] || fail "--model must not be empty."
  fi
  api_config_requested=true
  warn "--api-key can be exposed by shell history and process listings."
  case "$api_base_url" in
    [Hh][Tt][Tt][Pp]://*)
      warn "the API key will be transmitted over unencrypted HTTP."
      ;;
  esac
elif [ "$xtrace_was_enabled" = true ]; then
  set -x
fi

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_ROOT="$CODEX_HOME_DIR/packages/codez"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
LOCK_DIR="$INSTALL_ROOT/install.lock.d"
BIN_PATH="$BIN_DIR/codez"

detect_target
extract_bundle "$bundle_path"
mkdir -p "$INSTALL_ROOT" "$RELEASES_DIR" "$BIN_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "Another Codez installation is already running: $LOCK_DIR"
fi
lock_acquired=true

if [ "$api_config_requested" = true ]; then
  prepare_rollback
fi
install_from_bundle

if [ "$api_config_requested" = true ]; then
  if [ "$model_seen" = true ]; then
    if ! printf '%s\n' "$api_key" | "$BIN_PATH" offline-api-bootstrap \
      --api-base-url "$api_base_url" --model "$model"
    then
      api_key=""
      fail "Codez could not save the internal API configuration."
    fi
  elif ! printf '%s\n' "$api_key" | "$BIN_PATH" offline-api-bootstrap \
    --api-base-url "$api_base_url"
  then
    api_key=""
    fail "Codez could not save the internal API configuration."
  fi
  api_key=""
  commit_install
fi

echo
echo "==> Installed Codez offline at $BIN_PATH"
echo "==> Internal helper remains private at $CURRENT_LINK/bin/codex-code-mode-host"
if [ "$api_config_requested" = true ]; then
  echo "==> Configured API endpoint: $api_base_url"
  if [ "$model_seen" = true ]; then
    echo "==> Configured default model: $model"
  fi
fi
