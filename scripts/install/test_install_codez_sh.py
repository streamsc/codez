#!/usr/bin/env python3

import hashlib
import io
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
                self.assertFalse((public_bin / "codex-code-mode-host").exists())

                current = codez_home / "packages" / "codez" / "current"
                self.assertTrue(current.is_symlink())
                self.assertIn(target, os.readlink(current))
                self.assertTrue((current / "bin" / "codez").is_file())
                self.assertTrue((current / "bin" / "codex-code-mode-host").is_file())
                self.assertEqual(
                    subprocess.check_output([public_bin / "codez"], text=True).strip(),
                    "codez 0.144.4-r1",
                )
                if is_linux:
                    bwrap = current / "codex-resources" / "bwrap"
                    self.assertTrue(bwrap.is_file())
                    self.assertTrue(os.access(bwrap, os.X_OK))

    def test_rejects_unsupported_platforms(self) -> None:
        unsupported = (
            ("Darwin", "x86_64", "Apple Silicon macOS only"),
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

    def _write_release(
        self,
        release_dir: Path,
        target: str,
        *,
        is_linux: bool,
        include_bwrap: bool = True,
    ) -> str:
        asset = f"codez-package-{target}.tar.gz"
        archive_path = release_dir / asset
        files = {
            "bin/codez": b"#!/bin/sh\nprintf 'codez 0.144.4-r1\\n'\n",
            "bin/codex-code-mode-host": b"#!/bin/sh\nexit 0\n",
            "codex-package.json": b'{"variant":"codez"}\n',
        }
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
