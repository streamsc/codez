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
release_created=false
DAEMON_ONLY=0
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
  snapshot_path "$INSTALL_ROOT/selection-history" history
  snapshot_path "$INSTALL_ROOT/auto-update-version" auto-update
  rollback_active=true
}

rollback_install() {
  if [ "$release_created" = true ]; then
    rm -rf "$release_dir"
    if [ -d "$rollback_dir/release-dir" ]; then
      mv "$rollback_dir/release-dir" "$release_dir"
    fi
  fi
  restore_path "$CURRENT_LINK" current
  restore_path "$BIN_PATH" public-bin
  restore_path "$CODEX_HOME_DIR/config.toml" config
  restore_path "$CODEX_HOME_DIR/auth.json" auth
  restore_path "$INSTALL_ROOT/selection-history" history
  restore_path "$INSTALL_ROOT/auto-update-version" auto-update
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

  for required in bin/codez bin/codez-code-mode-host bin/codex-exec-server codex-path/rg codex-package.json; do
    [ -f "$stage_dir/$required" ] || fail "Release archive is missing $required."
  done
  if [ "$system" = Linux ]; then
    [ -f "$stage_dir/codex-resources/bwrap" ] || fail "Linux release archive is missing codex-resources/bwrap."
  fi

  package_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$stage_dir/codex-package.json" | head -n 1)"
  package_variant="$(sed -n 's/.*"variant"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$stage_dir/codex-package.json" | head -n 1)"
  release_version="${release_tag#codez-v}"
  [ "$package_variant" = codez ] || fail "Release archive is not a Codez package."
  [ "$package_version" = "$release_version" ] \
    || fail "Package metadata version does not match manifest release version."
  expected_version="$release_version"
  validate_package_metadata || fail "Package metadata does not match this release."
  chmod 0755 "$stage_dir/bin/codez" "$stage_dir/bin/codez-code-mode-host" "$stage_dir/bin/codex-exec-server" "$stage_dir/codex-path/rg"
  if [ "$system" = Linux ]; then chmod 0755 "$stage_dir/codex-resources/bwrap"; fi
  reported_version="$("$stage_dir/bin/codez" --version)"
  [ "$reported_version" = "codez $release_version" ] \
    || fail "Packaged Codez binary did not report the expected version."

  ln -s bin/codez "$stage_dir/codez"
  release_dir="$RELEASES_DIR/${release_tag#codez-v}-$TARGET"
  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    diff -r "$stage_dir" "$release_dir" >/dev/null || fail "Refusing to overwrite existing Codez release $release_dir."
    rm -rf "$stage_dir"
  else
    mv "$stage_dir" "$release_dir"
    release_created=true
  fi
  stage_dir=""

  previous_dir="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || previous_dir=""
  selected_dir="$(cd -P "$release_dir" && pwd)"
  if [ "$previous_dir" != "$selected_dir" ]; then
    tmp_current="$INSTALL_ROOT/.current.$$"
    ln -s "$release_dir" "$tmp_current"
    # GNU/BSD mv both replace the symlink without following its directory target.
    if ! mv -Tf "$tmp_current" "$CURRENT_LINK" 2>/dev/null &&
      ! mv -hf "$tmp_current" "$CURRENT_LINK" 2>/dev/null; then
      rm -f "$CURRENT_LINK"
      mv "$tmp_current" "$CURRENT_LINK"
    fi
    record_selection_history || warn "Could not record selection history; cleanup will be skipped."
  fi
  rm -f "$INSTALL_ROOT/auto-update-version"

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
os="$(printf '%s' "$system" | tr '[:upper:]' '[:lower:]')"
extract_bundle "$bundle_path"
mkdir -p "$INSTALL_ROOT" "$RELEASES_DIR" "$BIN_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "Another Codez installation is already running: $LOCK_DIR"
fi
lock_acquired=true
cleanup_stale_install_artifacts

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

if ! prune_standalone_releases; then
  warn "Could not safely inspect old Codez releases; skipped remaining cleanup."
fi

echo
echo "==> Installed Codez offline at $BIN_PATH"
echo "==> Internal helper remains private at $CURRENT_LINK/bin/codez-code-mode-host"
if [ "$api_config_requested" = true ]; then
  echo "==> Configured API endpoint: $api_base_url"
  if [ "$model_seen" = true ]; then
    echo "==> Configured default model: $model"
  fi
fi
