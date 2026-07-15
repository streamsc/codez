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
ASSET = "codez-package-aarch64-apple-darwin.tar.gz"
CHECKSUMS = "codez-package_SHA256SUMS"


class InstallCodezShTest(unittest.TestCase):
    def test_installs_codez_without_exposing_the_shared_helper_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            release_dir = root / "release"
            fake_bin = root / "fake-bin"
            codez_home = root / "codex-home"
            public_bin = root / "public-bin"
            release_dir.mkdir()
            fake_bin.mkdir()
            self._write_release(release_dir)
            self._write_fake_commands(fake_bin)

            env = {
                **os.environ,
                "PATH": os.pathsep.join(
                    [str(fake_bin), "/usr/local/bin", "/usr/bin", "/bin"]
                ),
                "CODEX_HOME": str(codez_home),
                "CODEX_INSTALL_DIR": str(public_bin),
                "FAKE_CODEZ_RELEASE_DIR": str(release_dir),
            }
            result = subprocess.run(
                [str(INSTALLER)],
                check=False,
                capture_output=True,
                env=env,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("codez 0.144.4-r1", result.stdout)
            self.assertTrue((public_bin / "codez").is_symlink())
            self.assertFalse((public_bin / "codex-code-mode-host").exists())

            current = codez_home / "packages" / "codez" / "current"
            self.assertTrue(current.is_symlink())
            self.assertTrue((current / "bin" / "codez").is_file())
            self.assertTrue((current / "bin" / "codex-code-mode-host").is_file())
            self.assertEqual(
                subprocess.check_output([public_bin / "codez"], text=True).strip(),
                "codez 0.144.4-r1",
            )

    def _write_release(self, release_dir: Path) -> None:
        archive_path = release_dir / ASSET
        files = {
            "bin/codez": b"#!/bin/sh\nprintf 'codez 0.144.4-r1\\n'\n",
            "bin/codex-code-mode-host": b"#!/bin/sh\nexit 0\n",
            "codex-package.json": b'{"variant":"codez"}\n',
        }
        with tarfile.open(archive_path, "w:gz") as archive:
            for name, contents in files.items():
                info = tarfile.TarInfo(name)
                info.mode = 0o755 if name.startswith("bin/") else 0o644
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))

        digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        (release_dir / CHECKSUMS).write_text(f"{digest}  {ASSET}\n", encoding="utf-8")

    def _write_fake_commands(self, fake_bin: Path) -> None:
        uname = fake_bin / "uname"
        uname.write_text(
            "#!/bin/sh\n"
            'case "${1:-}" in\n'
            "  -s) printf 'Darwin\\n' ;;\n"
            "  -m) printf 'arm64\\n' ;;\n"
            "  *) printf 'Darwin\\n' ;;\n"
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
            f'  */{ASSET}) cp "$FAKE_CODEZ_RELEASE_DIR/{ASSET}" "$output" ;;\n'
            f'  */{CHECKSUMS}) cp "$FAKE_CODEZ_RELEASE_DIR/{CHECKSUMS}" "$output" ;;\n'
            "  *) printf 'unexpected URL: %s\\n' \"$url\" >&2; exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        curl.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
