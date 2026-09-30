#!/bin/sh

set -eu

RELEASE="${CODEX_RELEASE:-latest}"
DAEMON_ONLY="${CODEX_INSTALL_DAEMON_ONLY:-0}"
BIN_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
INSTALL_ROOT="$CODEX_HOME_DIR/packages/codez"
if [ "$DAEMON_ONLY" = "1" ]; then
  INSTALL_ROOT="$CODEX_HOME_DIR/packages/codez-app-server-daemon"
fi
RELEASES_DIR="$INSTALL_ROOT/releases"
CURRENT_LINK="$INSTALL_ROOT/current"
if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" = "1" ]; then
  [ "$DAEMON_ONLY" = "1" ] || { echo "Deferred selection requires a daemon-only installation." >&2; exit 1; }
  CURRENT_LINK="$INSTALL_ROOT/.migration-current"
fi
AUTO_UPDATE_VERSION="$INSTALL_ROOT/auto-update-version"
LOCK_FILE="$INSTALL_ROOT/install.lock"
LOCK_DIR="$INSTALL_ROOT/install.lock.d"
LOCK_STALE_AFTER_SECS=600
BIN_PATH="$BIN_DIR/codez"
REPOSITORY="streamsc/codez"
CHECKSUM_ASSET="codez-package_SHA256SUMS"

tmp_dir=""
lock_kind=""
stage_dir=""

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
  if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    rm -rf "$stage_dir"
  fi
  release_install_lock
}

trap cleanup EXIT HUP INT TERM

mkdir_lock_is_stale() {
  [ -d "$LOCK_DIR" ] || return 1

  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  started_at="$(cat "$LOCK_DIR/started_at" 2>/dev/null || true)"
  now="$(date +%s 2>/dev/null || printf '0')"

  case "$started_at" in
    ''|*[!0-9]*)
      started_at=0
      ;;
  esac

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  if [ "$started_at" -eq 0 ] || [ "$now" -eq 0 ]; then
    return 0
  fi

  [ $((now - started_at)) -ge "$LOCK_STALE_AFTER_SECS" ]
}

acquire_install_lock() {
  mkdir -p "$INSTALL_ROOT"

  if [ "$system" = "Darwin" ] && command -v lockf >/dev/null 2>&1; then
    : >>"$LOCK_FILE"
    exec 9<>"$LOCK_FILE"
    lockf 9
    lock_kind="lockf"
    return
  fi

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock 9
    lock_kind="flock"
    return
  fi

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if mkdir_lock_is_stale; then
      echo "Removing stale installer lock at $LOCK_DIR" >&2
      rm -rf "$LOCK_DIR"
      continue
    fi
    sleep 1
  done

  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  date +%s >"$LOCK_DIR/started_at" 2>/dev/null || true
  lock_kind="mkdir"
}

release_install_lock() {
  if [ "$lock_kind" = "mkdir" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  elif [ "$lock_kind" = "flock" ] || [ "$lock_kind" = "lockf" ]; then
    exec 9>&- 2>/dev/null || true
  fi
  lock_kind=""
}

replace_path_with_symlink() {
  link_path="$1"
  link_target="$2"
  tmp_link="$3"

  rm -f "$tmp_link"
  ln -s "$link_target" "$tmp_link"

  if mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  if mv -hf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  rm -f "$link_path"
  mv -f "$tmp_link" "$link_path"
}

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
acquire_install_lock
if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" = "1" ] &&
  { [ -e "$INSTALL_ROOT/current" ] || [ -L "$INSTALL_ROOT/current" ]; }; then
  echo "A dedicated daemon is already selected; retry the update." >&2
  exit 1
fi
if [ "${CODEX_INSTALL_IF_LATEST:-}" = "1" ] || [ "${CODEX_INSTALL_IF_CURRENT:-}" = "1" ]; then
  guarded_release="${CODEX_UPDATE_FROM_RELEASE:-}"
  current_release_dir="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || current_release_dir=""
  releases_dir="$(cd -P "$RELEASES_DIR" 2>/dev/null && pwd)"
  if [ "$RELEASE" != "latest" ] || [ -z "$guarded_release" ] ||
    [ "$current_release_dir" != "$releases_dir/$guarded_release" ]; then
    if [ "${CODEX_INSTALL_IF_CURRENT:-}" = "1" ]; then
      echo "Daemon selection changed; retry the update." >&2
      exit 1
    fi
    exit 0
  fi
  if [ "${CODEX_INSTALL_IF_CURRENT:-}" != "1" ] &&
    [ "$(cat "$AUTO_UPDATE_VERSION" 2>/dev/null || true)" != "$guarded_release" ]; then
    exit 0
  fi
fi

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

expected_version="${tag#codez-v}"
if [ "$("$stage_dir/bin/codez" --version)" != "codez $expected_version" ]; then
  echo "Installed Codez command did not report expected version $expected_version." >&2
  exit 1
fi
if [ "$DAEMON_ONLY" = "1" ]; then
  # Match the alias created when Rust seeds a daemon from the CLI package.
  ln -s bin/codez "$stage_dir/codez"
fi
if [ "$DAEMON_ONLY" = "1" ] && { [ -e "$release_dir" ] || [ -L "$release_dir" ]; }; then
  # Never replace files that may back a running daemon process.
  diff -r "$stage_dir" "$release_dir" >/dev/null || {
    echo "Refusing to overwrite existing daemon release $release_dir." >&2; exit 1;
  }
  rm -rf "$stage_dir"
else
  rm -rf "$release_dir"
  mv "$stage_dir" "$release_dir"
fi
if [ "$DAEMON_ONLY" = "1" ] && [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" != "1" ]; then
  "$release_dir/bin/codez" app-server daemon pid-update-loop --check-package-ownership >/dev/null 2>&1 || {
    echo "The release does not support daemon-owned packages; selection was left unchanged." >&2; exit 1;
  }
fi

tmp_current="$INSTALL_ROOT/.current.$$"
replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$tmp_current"
if [ "$RELEASE" = "latest" ]; then
  printf '%s' "${tag#codez-v}-$TARGET" > "$AUTO_UPDATE_VERSION.tmp.$$"
  mv -f "$AUTO_UPDATE_VERSION.tmp.$$" "$AUTO_UPDATE_VERSION"
else
  rm -f "$AUTO_UPDATE_VERSION"
fi
if [ "$DAEMON_ONLY" = "1" ]; then
  exit 0
fi

tmp_bin="$BIN_DIR/.codez.$$"
replace_path_with_symlink "$BIN_PATH" "$CURRENT_LINK/bin/codez" "$tmp_bin"

"$BIN_PATH" --version
echo
echo "==> Installed Codez at $BIN_PATH"
echo "==> Internal helper remains private at $CURRENT_LINK/bin/codex-code-mode-host"
