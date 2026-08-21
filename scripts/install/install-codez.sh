#!/bin/sh

set -eu

RELEASE="${CODEX_RELEASE:-latest}"
BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME_DIR/packages/codez"
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
LOCK_DIR="$INSTALL_ROOT/install.lock.d"
BIN_PATH="$BIN_DIR/codez"
REPOSITORY="streamsc/codez"
CHECKSUM_ASSET="codez-package_SHA256SUMS"

tmp_dir=""
lock_acquired="false"

usage() {
  cat <<'EOF'
Usage: install-codez.sh [--release VERSION]

Installs the Codez release for macOS x86_64/ARM64 or Linux x86_64/ARM64.

Environment:
  CODEX_RELEASE      Release to install: latest, codez-vX.Y.Z-rN, or X.Y.Z-rN.
  CODEX_INSTALL_DIR  Directory for the public codez symlink (default: ~/.local/bin).
  CODEX_HOME         Shared Codex/Codez home directory (default: ~/.codex).
EOF
}

cleanup() {
  if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
  if [ "$lock_acquired" = "true" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

trap cleanup EXIT HUP INT TERM

download() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
  else
    echo "curl or wget is required to install Codez." >&2
    exit 1
  fi
}

download_text() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
  else
    echo "curl or wget is required to install Codez." >&2
    exit 1
  fi
}

verify_checksum() {
  checksum_line="$1"
  checksum_dir="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$checksum_dir" && printf '%s\n' "$checksum_line" | sha256sum -c -)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$checksum_dir" && printf '%s\n' "$checksum_line" | shasum -a 256 -c -)
  else
    echo "sha256sum or shasum is required to verify Codez." >&2
    exit 1
  fi
}

validate_tag() {
  tag="$1"
  if ! printf '%s\n' "$tag" | grep -Eq '^codez-v[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$'; then
    echo "Invalid Codez release '$tag'. Expected codez-vX.Y.Z-rN." >&2
    exit 1
  fi
}

resolve_tag() {
  requested="$1"
  case "$requested" in
    latest | "")
      metadata="$(download_text "https://api.github.com/repos/$REPOSITORY/releases/latest")"
      tag="$(printf '%s\n' "$metadata" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
      ;;
    codez-v*)
      tag="$requested"
      ;;
    *)
      tag="codez-v$requested"
      ;;
  esac
  validate_tag "$tag"
  printf '%s\n' "$tag"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)
      [ "$#" -ge 2 ] || { echo "--release requires a value." >&2; exit 1; }
      RELEASE="$2"
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

system="$(uname -s)"
machine="$(uname -m)"
case "$system:$machine" in
  Darwin:arm64 | Darwin:aarch64)
    TARGET="aarch64-apple-darwin"
    ;;
  Darwin:x86_64)
    TARGET="x86_64-apple-darwin"
    ;;
  Linux:x86_64 | Linux:amd64)
    TARGET="x86_64-unknown-linux-musl"
    ;;
  Linux:arm64 | Linux:aarch64)
    TARGET="aarch64-unknown-linux-musl"
    ;;
  Darwin:*)
    echo "Codez releases support x86_64 and ARM64 macOS only; detected $machine." >&2
    exit 1
    ;;
  Linux:*)
    echo "Codez releases support x86_64 and ARM64 Linux only; detected $machine." >&2
    exit 1
    ;;
  *)
    echo "Codez releases support macOS and Linux only; detected $system/$machine." >&2
    exit 1
    ;;
esac
ASSET="codez-package-$TARGET.tar.gz"

tag="$(resolve_tag "$RELEASE")"
release_url="https://github.com/$REPOSITORY/releases/download/$tag"
release_dir="$RELEASES_DIR/${tag#codez-v}-$TARGET"

mkdir -p "$INSTALL_ROOT" "$RELEASES_DIR" "$BIN_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Codez installation is already running: $LOCK_DIR" >&2
  exit 1
fi
lock_acquired="true"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codez-install.XXXXXX")"
archive_path="$tmp_dir/$ASSET"
checksum_path="$tmp_dir/$CHECKSUM_ASSET"

echo "==> Downloading Codez $tag"
download "$release_url/$ASSET" "$archive_path"
download "$release_url/$CHECKSUM_ASSET" "$checksum_path"

checksum_line="$(grep -E "^[0-9a-fA-F]{64}  $ASSET$" "$checksum_path" | head -n 1 || true)"
if [ -z "$checksum_line" ]; then
  echo "Checksum manifest does not contain $ASSET." >&2
  exit 1
fi
verify_checksum "$checksum_line" "$tmp_dir"

stage_dir="$RELEASES_DIR/.staging.$$"
rm -rf "$stage_dir"
mkdir -p "$stage_dir"
tar -xzf "$archive_path" -C "$stage_dir"

for required in bin/codez bin/codex-code-mode-host codex-package.json; do
  if [ ! -f "$stage_dir/$required" ]; then
    echo "Release archive is missing $required." >&2
    exit 1
  fi
done
chmod 0755 "$stage_dir/bin/codez" "$stage_dir/bin/codex-code-mode-host"
if [ "$system" = "Linux" ]; then
  if [ ! -f "$stage_dir/codex-resources/bwrap" ]; then
    echo "Linux release archive is missing codex-resources/bwrap." >&2
    exit 1
  fi
  chmod 0755 "$stage_dir/codex-resources/bwrap"
fi

rm -rf "$release_dir"
mv "$stage_dir" "$release_dir"

tmp_current="$INSTALL_ROOT/.current.$$"
ln -s "$release_dir" "$tmp_current"
rm -f "$CURRENT_LINK"
mv "$tmp_current" "$CURRENT_LINK"

tmp_bin="$BIN_DIR/.codez.$$"
ln -s "$CURRENT_LINK/bin/codez" "$tmp_bin"
rm -f "$BIN_PATH"
mv "$tmp_bin" "$BIN_PATH"

"$BIN_PATH" --version
echo
echo "==> Installed Codez at $BIN_PATH"
echo "==> Internal helper remains private at $CURRENT_LINK/bin/codex-code-mode-host"
