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

# Keep this process-aware cleanup aligned with the upstream Unix installer.
validate_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$'
}

parse_release_metadata() {
  # Bound awk's record size so compact, single-line JSON stays fast on every
  # supported awk implementation. JSON strings cannot contain literal newlines,
  # so the record boundaries inserted by fold do not change the document.
  LC_ALL=C fold -b -w 4096 | LC_ALL=C awk '
    function finish_string(value) {
      if (object_depth == 1 &&
          (key == "tag_name" || key == "version" || key == "target" || key == "entrypoint" || key == "variant" || key == "execServer")) {
        print key "\t" value
      } else if (object_depth == asset_object_depth) {
        if (key == "name") {
          asset_name = value
        } else if (key == "digest") {
          asset_digest = value
        }
      }

      expecting_value = 0
      key = ""
    }

    {
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)

        if (in_string) {
          if (escaped) {
            token = token "\\" char
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            in_string = 0
            if (string_is_value) {
              finish_string(token)
            } else {
              pending_key = token
            }
          } else {
            token = token char
          }
          continue
        }

        if (char == "\"") {
          in_string = 1
          token = ""
          escaped = 0
          string_is_value = expecting_value
        } else if (char == ":" && pending_key != "") {
          key = pending_key
          pending_key = ""
          expecting_value = 1
        } else if (char == "{") {
          object_depth++
          if (assets_array_depth != 0 &&
              array_depth == assets_array_depth &&
              asset_object_depth == 0) {
            asset_object_depth = object_depth
            asset_name = ""
            asset_digest = ""
          }
          expecting_value = 0
          key = ""
        } else if (char == "}") {
          if (object_depth == asset_object_depth) {
            if (asset_name != "" && asset_digest != "") {
              print "asset\t" asset_name "\t" asset_digest
            }
            asset_object_depth = 0
            asset_name = ""
            asset_digest = ""
          }
          object_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == "[") {
          array_depth++
          if (expecting_value && key == "assets" && object_depth == 1) {
            assets_array_depth = array_depth
          }
          expecting_value = 0
          key = ""
        } else if (char == "]") {
          if (array_depth == assets_array_depth) {
            assets_array_depth = 0
          }
          array_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == ",") {
          expecting_value = 0
          key = ""
          pending_key = ""
        }
      }
    }

    END {
      if (in_string || object_depth != 0 || array_depth != 0) {
        exit 1
      }
    }
  '
}

cleanup_stale_install_artifacts() {
  mkdir -p "$RELEASES_DIR" "$INSTALL_ROOT"

  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -name '.staging.*' -exec rm -rf {} +
  find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 -name '.current.*' -exec rm -f {} +

  if [ "$DAEMON_ONLY" != "1" ] && [ -d "$BIN_DIR" ]; then
    find "$BIN_DIR" -mindepth 1 -maxdepth 1 -name '.codez.*' -exec rm -f {} +
  fi
}

record_standalone_releases_in_use() {
  # /proc also catches old clients with no session records. On macOS lsof
  # checks every open file in the release, including running helper programs.
  if [ "$os" = "linux" ]; then
    [ -r /proc/self/mountinfo ] && [ -L /proc/self/exe ] || return 1
    # hidepid can omit other users' processes entirely; do not assume an
    # incomplete process listing proves an older release is unused.
    if grep -E '(^|[ ,])hidepid=[^0, ]' /proc/self/mountinfo >/dev/null; then
      return 1
    fi
    : > "$tmp_dir/in-use" || return 1
    for process in /proc/[0-9]*; do
      if executable="$(readlink "$process/exe" 2>/dev/null)"; then
        printf 'n%s\n' "$executable" >> "$tmp_dir/in-use" || return 1
      elif [ -d "$process" ]; then
        # Even same-user ssh-agent/systemd processes may deny exe inspection.
        # Only an unreadable Codez or bundled helper prevents safe pruning.
        process_name="$(cat "$process/comm" 2>/dev/null)" || {
          [ ! -d "$process" ] && continue
          return 1
        }
        # Linux truncates comm to 15 bytes, including the code-mode host.
        case "$process_name" in
          codez* | codex-exec-server | rg | bwrap)
            # A zombie has no files left open, even if its parent never reaps it.
            grep -Eq '^State:[[:space:]]*Z' "$process/status" 2>/dev/null && continue
            [ ! -d "$process" ] && continue
            return 1
            ;;
        esac
      fi
    done
  else
    # macOS lsof silently omits other users' processes, even with no errors.
    # ps can still report their executable names. As on Linux, decline to
    # prune when an uninspectable Codez or helper may be using a release.
    current_uid="$(id -u)" || return 1
    ps -axo uid=,comm= > "$tmp_dir/processes" || return 1
    [ -s "$tmp_dir/processes" ] || return 1
    while read -r process_uid process_name; do
      [ "$process_uid" = "$current_uid" ] && continue
      case "${process_name##*/}" in
        codez* | codex-exec-server | rg | bwrap) return 1 ;;
      esac
    done < "$tmp_dir/processes"
    if /usr/sbin/lsof -nP -F n +D "$releases" > "$tmp_dir/in-use" 2> "$tmp_dir/lsof-error"; then
      :
    else
      # macOS lsof +D can return 1 with matches when some files are not open.
      # Keep those matches, but reject other failures and any stderr below.
      [ "$?" -eq 1 ] || return 1
    fi
    [ ! -s "$tmp_dir/lsof-error" ] || return 1
  fi
}

release_is_unused() {
  if [ "$os" = "linux" ]; then
    path_field="n$1"
  else
    # lsof +D scopes the scan to this tree, but may escape bytes in CODEX_HOME.
    # Match the installer-owned ASCII path, including the temporary retirement name.
    path_field="/packages/${INSTALL_ROOT##*/}/releases/${1#"$releases"/}"
  fi
  # Appending / also matches a process whose cwd is the release root itself.
  LC_ALL=C RELEASE_PATH="$path_field/" awk 'index($0 "/", ENVIRON["RELEASE_PATH"]) { exit 1 }' "$tmp_dir/in-use"
}

# Run under the install lock, after the visible command has been verified.
# Only retire ordinary, manifest-owned packages; never retry a retired tree.
prune_standalone_releases() (
  [ ! -L "$CODEX_HOME_DIR/packages" ] &&
    [ ! -L "$INSTALL_ROOT" ] && [ ! -L "$RELEASES_DIR" ] || return 1
  releases="$(cd -P "$RELEASES_DIR" && pwd)" || return 1
  # Local process inspection cannot establish whether a network home is in
  # use on another host. df -l excludes remotely mounted filesystems.
  df -lP "$releases" > /dev/null 2> "$tmp_dir/df-error" || return 1
  [ ! -s "$tmp_dir/df-error" ] || return 1
  selected="$(cd -P "$CURRENT_LINK" && pwd)" || return 1
  history="$(cat "$INSTALL_ROOT/selection-history")" || return 1
  previous="$(printf '%s\n' "$history" | sed -n '2p')"
  case "$previous" in
    */* | . | ..) return 1 ;;
  esac
  identity="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK" 2>/dev/null ||
    LC_ALL=C stat -f '%d %i %Fc' "$CURRENT_LINK")" || return 1
  [ "$selected" = "$releases/${selected##*/}" ] &&
    [ "$history" = "$(printf '%s\n%s\n%s' "${selected##*/}" "$previous" "$identity")" ] ||
    return 1
  record_standalone_releases_in_use || return 1
  restore_candidate=""
  # A stopped install must not strand a late-starting release in retirement.
  trap 'if [ -n "$restore_candidate" ] && [ -d "$retired/release" ] &&
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    mv "$retired/release" "$candidate" && rmdir "$retired"
  fi' EXIT
  trap 'exit 1' HUP INT TERM

  for candidate in "$releases"/*; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] &&
      [ "$candidate" != "$selected" ] && [ "${candidate##*/}" != "$previous" ] || continue
    release_is_unused "$candidate" || continue
    [ -f "$candidate/codex-package.json" ] && [ ! -L "$candidate/codex-package.json" ] || continue
    metadata="$(parse_release_metadata < "$candidate/codex-package.json")" || continue
    version="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "version" {print $2}')"
    target="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "target" {print $2}')"
    entrypoint="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "entrypoint" {print $2}')"
    [ "${candidate##*/}" = "$version-$target" ] && [ "$version" != "latest" ] &&
      [ "$entrypoint" = "bin/codez" ] && [ -f "$candidate/bin/codez" ] || continue
    validate_version "$version" >/dev/null 2>&1 || continue
    case "$target" in
      aarch64-apple-darwin | x86_64-apple-darwin | aarch64-unknown-linux-musl | x86_64-unknown-linux-musl) ;;
      *) continue ;;
    esac

    # Reject symlinks (except the installer's own alias), special files and
    # mounts before rm -r. find -xdev alone would not protect nested mounts.
    [ "$(readlink "$candidate/codez" 2>/dev/null)" = "bin/codez" ] || continue
    if ! find "$candidate" -xdev ! -type f ! -type d ! -path "$candidate/codez" -print > "$tmp_dir/unowned"; then
      continue
    fi
    [ ! -s "$tmp_dir/unowned" ] || continue
    if [ "$os" = "linux" ]; then
      # mountinfo escapes spaces, tabs, newlines, and backslashes in paths.
      if ! CODEX_PRUNE_RELEASE="$candidate" LC_ALL=C awk '
        BEGIN { release = ENVIRON["CODEX_PRUNE_RELEASE"] }
        { path = $5; gsub(/\\040/, " ", path); gsub(/\\011/, "\t", path)
          gsub(/\\012/, "\n", path); gsub(/\\134/, "\\", path)
          if (path == release || index(path, release "/") == 1) found = 1 }
        END { exit found ? 1 : 0 }
      ' /proc/self/mountinfo; then
        continue
      fi
    else
      device="$(stat -f '%d' "$releases")" || return 1
      if ! find "$candidate" -xdev -exec stat -f '%d' {} + > "$tmp_dir/devices"; then
        continue
      fi
      grep -vxF "$device" "$tmp_dir/devices" >/dev/null && continue
    fi

    retired="$(mktemp -d "$releases/.retired.XXXXXXXX")" || return 1
    restore_candidate=1
    if mv "$candidate" "$retired/release"; then
      # Block new launches at the original path before the final use check.
      # Some systems report the old executable path, so check both names.
      if ! record_standalone_releases_in_use ||
        ! release_is_unused "$candidate" || ! release_is_unused "$retired/release"; then
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
        mv "$retired/release" "$candidate" && rmdir "$retired" || return 1
        restore_candidate=""
        continue
      fi
      # Once proved unused, never restore a possibly partially deleted tree.
      restore_candidate=""
      find "$retired" -xdev -depth -delete || return 1
    else
      restore_candidate=""
      rmdir "$retired"
      return 1
    fi
  done
)

record_selection_history() (
  history="$INSTALL_ROOT/selection-history"
  selection_id="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK" 2>/dev/null ||
    LC_ALL=C stat -f '%d %i %Fc' "$CURRENT_LINK")" || exit 1
  printf '%s\n%s\n%s\n' "${release_dir##*/}" "${previous_dir##*/}" "$selection_id" > "$history.tmp.$$" &&
    mv -f "$history.tmp.$$" "$history"
)

validate_package_metadata() {
  metadata="$(parse_release_metadata < "$stage_dir/codex-package.json")" || return 1
  for expected in "version $expected_version" "variant codez" "target $TARGET" "entrypoint bin/codez" "execServer bin/codex-exec-server"; do
    key="${expected%% *}"
    value="${expected#* }"
    actual="$(printf '%s\n' "$metadata" | awk -F '\t' -v key="$key" '$1 == key {print $2}')"
    [ "$actual" = "$value" ] || {
      echo "Invalid Codez package metadata: $key must be $value." >&2
      return 1
    }
  done
}

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
os="$(printf '%s' "$system" | tr '[:upper:]' '[:lower:]')"
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
cleanup_stale_install_artifacts
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

for required in bin/codez bin/codez-code-mode-host bin/codex-exec-server codex-path/rg codex-package.json; do
  if [ ! -f "$stage_dir/$required" ]; then
    echo "Release archive is missing $required." >&2
    exit 1
  fi
done
chmod 0755 "$stage_dir/bin/codez" "$stage_dir/bin/codez-code-mode-host" "$stage_dir/bin/codex-exec-server"
if [ "$system" = "Linux" ]; then
  if [ ! -f "$stage_dir/codex-resources/bwrap" ]; then
    echo "Linux release archive is missing codex-resources/bwrap." >&2
    exit 1
  fi
  chmod 0755 "$stage_dir/codex-resources/bwrap"
fi

expected_version="${tag#codez-v}"
validate_package_metadata || exit 1
chmod 0755 "$stage_dir/codex-path/rg"
if [ "$("$stage_dir/bin/codez" --version)" != "codez $expected_version" ]; then
  echo "Installed Codez command did not report expected version $expected_version." >&2
  exit 1
fi
ln -s bin/codez "$stage_dir/codez"
if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
  # Never replace files that may back a running daemon process.
  diff -r "$stage_dir" "$release_dir" >/dev/null || {
    echo "Refusing to overwrite existing Codez release $release_dir." >&2; exit 1;
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

previous_dir="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || previous_dir=""
selected_dir="$(cd -P "$release_dir" && pwd)"
if [ "$previous_dir" != "$selected_dir" ]; then
  tmp_current="$INSTALL_ROOT/.current.$$"
  replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$tmp_current"
  if [ "${CODEX_INSTALL_DEFER_SELECTION:-0}" != "1" ]; then
    record_selection_history || echo "Could not record selection history; cleanup will be skipped." >&2
  fi
fi
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
if ! prune_standalone_releases; then
  echo "Could not safely inspect old Codez releases; skipped remaining cleanup." >&2
fi
echo
echo "==> Installed Codez at $BIN_PATH"
echo "==> Internal helper remains private at $CURRENT_LINK/bin/codez-code-mode-host"
