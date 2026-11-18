#!/usr/bin/env python3

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "scripts" / "install" / "install-codez.sh"
TAG = "codez-v0.144.4-r1"
CHECKSUMS = "codez-package_SHA256SUMS"
SUPPORTED_PLATFORMS = (
    ("Darwin", "arm64", "aarch64-apple-darwin", False),
    ("Darwin", "x86_64", "x86_64-apple-darwin", False),
    ("Linux", "x86_64", "x86_64-unknown-linux-musl", True),
    ("Linux", "aarch64", "aarch64-unknown-linux-musl", True),
)


class InstallCodezShTest(unittest.TestCase):
    def test_installs_supported_platform_packages(self) -> None:
        for system, machine, target, is_linux in SUPPORTED_PLATFORMS:
            with (
                self.subTest(system=system, machine=machine),
                tempfile.TemporaryDirectory() as temp_dir,
            ):
                root = Path(temp_dir)
                release_dir = root / "release"
                fake_bin = root / "fake-bin"
                codez_home = root / "codex-home"
                public_bin = root / "public-bin"
                release_dir.mkdir()
                fake_bin.mkdir()
                asset = self._write_release(release_dir, target, is_linux=is_linux)
                self._write_fake_commands(fake_bin)

                result = subprocess.run(
                    [str(INSTALLER)],
                    check=False,
                    capture_output=True,
                    env=self._environment(
                        fake_bin,
                        codez_home,
                        public_bin,
                        release_dir,
                        system,
                        machine,
                    ),
                    text=True,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"==> Downloading Codez {TAG}", result.stdout)
                self.assertIn(asset, result.stdout)
                self.assertIn("codez 0.144.4-r1", result.stdout)
                self.assertIn(
                    f"==> Installed Codez at {public_bin / 'codez'}",
                    result.stdout,
                )
                self.assertIn("==> Internal helper remains private at ", result.stdout)
                self.assertTrue((public_bin / "codez").is_symlink())
                self.assertFalse((public_bin / "codez-code-mode-host").exists())

                current = codez_home / "packages" / "codez" / "current"
                self.assertTrue(current.is_symlink())
                self.assertIn(target, os.readlink(current))
                self.assertTrue((current / "bin" / "codez").is_file())
                self.assertTrue((current / "bin" / "codez-code-mode-host").is_file())
                self.assertTrue(os.access(current / "bin/codex-exec-server", os.X_OK))
                self.assertFalse((public_bin / "codex-exec-server").exists())
                self.assertEqual(
                    subprocess.check_output([public_bin / "codez"], text=True).strip(),
                    "codez 0.144.4-r1",
                )
                if is_linux:
                    bwrap = current / "codex-resources" / "bwrap"
                    self.assertTrue(bwrap.is_file())
                    self.assertTrue(os.access(bwrap, os.X_OK))

    def test_same_version_reuses_package_and_rejects_changed_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = root / "release"
            fake_bin = root / "fake-bin"
            release.mkdir()
            fake_bin.mkdir()
            self._write_fake_commands(fake_bin)
            self._write_release(release, "aarch64-apple-darwin", is_linux=False)
            env = self._environment(
                fake_bin, root / "home", root / "bin", release, "Darwin", "arm64"
            )
            current = root / "home/packages/codez/current"
            for attempt in range(2):
                installed = subprocess.run(
                    [str(INSTALLER)], env=env, capture_output=True, text=True
                )
                self.assertEqual(installed.returncode, 0, installed.stderr)
                if attempt == 0:
                    identity = (current / "bin/codez").stat().st_ino
                else:
                    self.assertEqual((current / "bin/codez").stat().st_ino, identity)
            helper = current / "bin/codez-code-mode-host"
            helper.write_text("selected helper must survive")
            rejected = subprocess.run(
                [str(INSTALLER)], env=env, capture_output=True, text=True
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Refusing to overwrite", rejected.stderr)
            self.assertEqual(helper.read_text(), "selected helper must survive")
            self.assertEqual((current / "bin/codez").stat().st_ino, identity)

    def test_rejects_unsupported_platforms(self) -> None:
        unsupported = (
            ("Darwin", "powerpc", "x86_64 and ARM64 macOS only"),
            ("Linux", "riscv64", "x86_64 and ARM64 Linux only"),
            ("FreeBSD", "x86_64", "macOS and Linux only"),
        )
        for system, machine, expected_error in unsupported:
            with (
                self.subTest(system=system, machine=machine),
                tempfile.TemporaryDirectory() as temp_dir,
            ):
                root = Path(temp_dir)
                fake_bin = root / "fake-bin"
                fake_bin.mkdir()
                self._write_fake_commands(fake_bin)
                result = subprocess.run(
                    [str(INSTALLER)],
                    check=False,
                    capture_output=True,
                    env=self._environment(
                        fake_bin,
                        root / "codex-home",
                        root / "public-bin",
                        root / "release",
                        system,
                        machine,
                    ),
                    text=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)

    def test_executor_validation_preserves_existing_selection(self) -> None:
        for include_executor, executor_path in (
            (False, "bin/codex-exec-server"),
            (True, "bin/another-executor"),
        ):
            with (
                self.subTest(include_executor=include_executor),
                tempfile.TemporaryDirectory() as temp,
            ):
                root = Path(temp)
                release = root / "release"
                fake_bin = root / "fake-bin"
                release.mkdir()
                fake_bin.mkdir()
                self._write_fake_commands(fake_bin)
                target = "aarch64-apple-darwin"
                env = self._environment(
                    fake_bin, root / "home", root / "bin", release, "Darwin", "arm64"
                )
                self._write_release(release, target, is_linux=False)
                installed = subprocess.run(
                    [str(INSTALLER)], env=env, capture_output=True, text=True
                )
                self.assertEqual(installed.returncode, 0, installed.stderr)
                current = root / "home/packages/codez/current"
                history = current.parent / "selection-history"
                before = (os.readlink(current), history.read_bytes())
                self._write_release(
                    release,
                    target,
                    is_linux=False,
                    include_executor=include_executor,
                    executor_path=executor_path,
                )
                rejected = subprocess.run(
                    [str(INSTALLER)], env=env, capture_output=True, text=True
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("exec", rejected.stderr)
                self.assertEqual((os.readlink(current), history.read_bytes()), before)

    def test_rejects_linux_package_without_bwrap(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            release_dir = root / "release"
            fake_bin = root / "fake-bin"
            release_dir.mkdir()
            fake_bin.mkdir()
            self._write_release(
                release_dir,
                "x86_64-unknown-linux-musl",
                is_linux=True,
                include_bwrap=False,
            )
            self._write_fake_commands(fake_bin)

            result = subprocess.run(
                [str(INSTALLER)],
                check=False,
                capture_output=True,
                env=self._environment(
                    fake_bin,
                    root / "codex-home",
                    root / "public-bin",
                    release_dir,
                    "Linux",
                    "x86_64",
                ),
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "Linux release archive is missing codex-resources/bwrap.",
                result.stderr,
            )

    def test_daemon_selection_and_update_guards(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            release = root / "release"
            fake_bin = root / "fake-bin"
            release.mkdir()
            fake_bin.mkdir()
            target = "x86_64-unknown-linux-musl"
            self._write_release(release, target, is_linux=True)
            self._write_fake_commands(fake_bin)
            home = root / "home"
            public = root / "bin"
            env = self._environment(fake_bin, home, public, release, "Linux", "x86_64")
            env["CODEX_INSTALL_DAEMON_ONLY"] = "1"
            package = home / "packages/codez-app-server-daemon"
            release_name = f"{TAG.removeprefix('codez-v')}-{target}"

            def install(**updates: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [str(INSTALLER)],
                    env={**env, **updates},
                    capture_output=True,
                    text=True,
                )

            pending = install(CODEX_INSTALL_DEFER_SELECTION="1")
            self.assertEqual(pending.returncode, 0, pending.stderr)
            self.assertFalse((package / "current").exists())
            self.assertTrue((package / ".migration-current/bin/codez").is_file())
            self.assertEqual(
                (package / "auto-update-version").read_text(), release_name
            )
            self.assertFalse((public / "codez").exists())
            (package / ".migration-current").rename(package / "current")

            # Rust prepare_install seeds daemon packages with this root alias.
            alias = package / "current/codez"
            alias.unlink(missing_ok=True)
            alias.symlink_to("bin/codez")
            binary_inode = (package / "current/bin/codez").stat().st_ino
            seeded = install(
                CODEX_INSTALL_IF_LATEST="1", CODEX_UPDATE_FROM_RELEASE=release_name
            )
            self.assertEqual(seeded.returncode, 0, seeded.stderr)
            self.assertEqual(
                (package / "current/bin/codez").stat().st_ino, binary_inode
            )
            self.assertEqual(os.readlink(alias), "bin/codez")

            changed = install(
                CODEX_INSTALL_IF_CURRENT="1", CODEX_UPDATE_FROM_RELEASE="stale"
            )
            self.assertNotEqual(changed.returncode, 0)
            self.assertIn("Daemon selection changed", changed.stderr)
            scheduled = install(
                CODEX_INSTALL_IF_LATEST="1", CODEX_UPDATE_FROM_RELEASE="stale"
            )
            self.assertEqual(scheduled.returncode, 0, scheduled.stderr)
            self.assertNotIn("Downloading", scheduled.stdout)
            repeated = install(CODEX_INSTALL_DEFER_SELECTION="1")
            self.assertNotEqual(repeated.returncode, 0)

            pinned = install(CODEX_RELEASE=TAG)
            self.assertEqual(pinned.returncode, 0, pinned.stderr)
            self.assertFalse((package / "auto-update-version").exists())
            skipped = install(
                CODEX_INSTALL_IF_LATEST="1", CODEX_UPDATE_FROM_RELEASE=release_name
            )
            self.assertEqual(skipped.returncode, 0, skipped.stderr)
            self.assertNotIn("Downloading", skipped.stdout)
            explicit = install(
                CODEX_INSTALL_IF_CURRENT="1", CODEX_UPDATE_FROM_RELEASE=release_name
            )
            self.assertEqual(explicit.returncode, 0, explicit.stderr)
            self.assertEqual(
                (package / "auto-update-version").read_text(), release_name
            )
            self.assertFalse((public / "codez").exists())

    def _write_release(
        self,
        release_dir: Path,
        target: str,
        *,
        is_linux: bool,
        include_bwrap: bool = True,
        include_executor: bool = True,
        executor_path: str = "bin/codex-exec-server",
    ) -> str:
        asset = f"codez-package-{target}.tar.gz"
        archive_path = release_dir / asset
        files = {
            "bin/codez": b"#!/bin/sh\nprintf 'codez 0.144.4-r1\\n'\n",
            "bin/codez-code-mode-host": b"#!/bin/sh\nexit 0\n",
            "bin/codex-exec-server": b"#!/bin/sh\nexit 0\n",
            "codex-path/rg": b"#!/bin/sh\nexit 0\n",
            "codex-package.json": json.dumps(
                {
                    "version": TAG.removeprefix("codez-v"),
                    "target": target,
                    "variant": "codez",
                    "entrypoint": "bin/codez",
                    "execServer": executor_path,
                }
            ).encode(),
        }
        if not include_executor:
            del files["bin/codex-exec-server"]
        if is_linux and include_bwrap:
            files["codex-resources/bwrap"] = b"#!/bin/sh\nexit 0\n"
        with tarfile.open(archive_path, "w:gz") as archive:
            for name, contents in files.items():
                info = tarfile.TarInfo(name)
                info.mode = 0o755 if name.startswith("bin/") else 0o644
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))

        digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        (release_dir / CHECKSUMS).write_text(f"{digest}  {asset}\n", encoding="utf-8")
        return asset

    def _environment(
        self,
        fake_bin: Path,
        codez_home: Path,
        public_bin: Path,
        release_dir: Path,
        system: str,
        machine: str,
    ) -> dict[str, str]:
        return {
            **os.environ,
            "PATH": os.pathsep.join(
                [str(fake_bin), "/usr/local/bin", "/usr/bin", "/bin"]
            ),
            "CODEX_HOME": str(codez_home),
            "CODEX_INSTALL_DIR": str(public_bin),
            "FAKE_CODEZ_RELEASE_DIR": str(release_dir),
            "FAKE_UNAME_MACHINE": machine,
            "FAKE_UNAME_SYSTEM": system,
        }

    def _write_fake_commands(self, fake_bin: Path) -> None:
        uname = fake_bin / "uname"
        uname.write_text(
            "#!/bin/sh\n"
            'case "${1:-}" in\n'
            "  -s) printf '%s\\n' \"$FAKE_UNAME_SYSTEM\" ;;\n"
            "  -m) printf '%s\\n' \"$FAKE_UNAME_MACHINE\" ;;\n"
            "  *) printf '%s\\n' \"$FAKE_UNAME_SYSTEM\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        uname.chmod(0o755)

        curl = fake_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "output=''\n"
            "url=''\n"
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    -o) output="$2"; shift ;;\n'
            '    http*) url="$1" ;;\n'
            "  esac\n"
            "  shift\n"
            "done\n"
            'case "$url" in\n'
            f'  */releases/latest) printf \'{{"tag_name":"{TAG}"}}\\n\' ;;\n'
            f'  */{CHECKSUMS}) cp "$FAKE_CODEZ_RELEASE_DIR/{CHECKSUMS}" "$output" ;;\n'
            '  */codez-package-*.tar.gz) asset="${url##*/}"; cp "$FAKE_CODEZ_RELEASE_DIR/$asset" "$output" ;;\n'
            "  *) printf 'unexpected URL: %s\\n' \"$url\" >&2; exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
