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
INSTALLER = REPO_ROOT / "scripts/install/install-codez-offline.sh"
BUILDER = REPO_ROOT / "scripts/build_codez_offline_bundle.py"
TAG = "codez-v0.144.4-r1"
VERSION = "0.144.4-r1"
TARGETS = (
    ("Darwin", "arm64", "aarch64-apple-darwin", False),
    ("Linux", "x86_64", "x86_64-unknown-linux-musl", True),
    ("Linux", "aarch64", "aarch64-unknown-linux-musl", True),
)


class CodezOfflineInstallerTest(unittest.TestCase):
    def test_bundle_is_deterministic_and_directory_installs_all_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            assets = root / "assets"
            assets.mkdir()
            self._write_assets(assets)
            bundle_a = root / "a.tar.gz"
            bundle_b = root / "b.tar.gz"
            self._build_bundle(assets, bundle_a)
            self._build_bundle(assets, bundle_b)
            self.assertEqual(bundle_a.read_bytes(), bundle_b.read_bytes())

            extracted = root / "extracted"
            extracted.mkdir()
            with tarfile.open(bundle_a, "r:gz") as archive:
                archive.extractall(extracted)
            bundle_dir = next(extracted.iterdir())

            for system, machine, target, is_linux in TARGETS:
                with self.subTest(target=target):
                    install_root = root / target / "codex-home"
                    public_bin = root / target / "bin"
                    result = self._run_installer(
                        bundle_dir,
                        install_root,
                        public_bin,
                        system,
                        machine,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("==> Installed Codez offline at ", result.stdout)
                    current = install_root / "packages/codez/current"
                    self.assertTrue(current.is_symlink())
                    self.assertEqual(
                        subprocess.check_output(
                            [public_bin / "codez", "--version"], text=True
                        ).strip(),
                        f"codez {VERSION}",
                    )
                    self.assertTrue((current / "bin/codez").is_file())
                    self.assertTrue((current / "bin/codex-code-mode-host").is_file())
                    self.assertTrue((current / "codex-path/rg").is_file())
                    if is_linux:
                        self.assertTrue((current / "codex-resources/bwrap").is_file())

    def test_archive_input_and_checksum_failure_do_not_replace_current(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            assets = root / "assets"
            assets.mkdir()
            self._write_assets(assets)
            bundle = root / "bundle.tar.gz"
            self._build_bundle(assets, bundle)

            result = self._run_installer(
                bundle,
                root / "codex-home",
                root / "bin",
                "Linux",
                "x86_64",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            current = root / "codex-home/packages/codez/current"
            previous = os.readlink(current)

            broken = root / "broken"
            broken.mkdir()
            with tarfile.open(bundle, "r:gz") as archive:
                archive.extractall(broken)
            bundle_dir = next(broken.iterdir())
            archive_path = bundle_dir / "codez-package-x86_64-unknown-linux-musl.tar.gz"
            archive_path.write_bytes(archive_path.read_bytes() + b"corruption")

            failed = self._run_installer(
                bundle_dir,
                root / "codex-home",
                root / "bin",
                "Linux",
                "x86_64",
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("Checksum verification failed", failed.stderr)
            self.assertEqual(os.readlink(current), previous)

    def test_rejects_unknown_manifest_format_and_missing_platform_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            assets = root / "assets"
            assets.mkdir()
            self._write_assets(assets)
            bundle = root / "bundle.tar.gz"
            self._build_bundle(assets, bundle)

            extracted = root / "extracted"
            extracted.mkdir()
            with tarfile.open(bundle, "r:gz") as archive:
                archive.extractall(extracted)
            bundle_dir = next(extracted.iterdir())

            manifest = bundle_dir / "codez-offline-manifest"
            manifest.write_text(
                manifest.read_text(encoding="utf-8").replace(
                    "formatVersion=1", "formatVersion=2"
                ),
                encoding="utf-8",
            )
            failed_format = self._run_installer(
                bundle_dir,
                root / "format-home",
                root / "format-bin",
                "Linux",
                "x86_64",
            )
            self.assertNotEqual(failed_format.returncode, 0)
            self.assertIn(
                "Unsupported offline bundle format version", failed_format.stderr
            )
            self.assertFalse((root / "format-home/packages/codez/current").exists())

            manifest.write_text(
                manifest.read_text(encoding="utf-8").replace(
                    "formatVersion=2", "formatVersion=1"
                ),
                encoding="utf-8",
            )
            (bundle_dir / "codez-package-x86_64-unknown-linux-musl.tar.gz").unlink()
            failed_asset = self._run_installer(
                bundle_dir,
                root / "asset-home",
                root / "asset-bin",
                "Linux",
                "x86_64",
            )
            self.assertNotEqual(failed_asset.returncode, 0)
            self.assertIn(
                "Bundle is missing codez-package-x86_64-unknown-linux-musl.tar.gz",
                failed_asset.stderr,
            )

    def _build_bundle(self, assets: Path, output: Path) -> None:
        result = subprocess.run(
            [
                "python3",
                str(BUILDER),
                "--release-tag",
                TAG,
                "--asset-dir",
                str(assets),
                "--installer",
                str(INSTALLER),
                "--output",
                str(output),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def _run_installer(
        self,
        bundle: Path,
        codez_home: Path,
        public_bin: Path,
        system: str,
        machine: str,
    ) -> subprocess.CompletedProcess[str]:
        fake_bin = codez_home.parent / "fake-bin"
        fake_bin.mkdir(parents=True, exist_ok=True)
        uname = fake_bin / "uname"
        uname.write_text(
            "#!/bin/sh\n"
            'case "$1" in\n'
            f"  -s) printf '%s\\n' '{system}' ;;\n"
            f"  -m) printf '%s\\n' '{machine}' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        uname.chmod(0o755)
        no_network = fake_bin / "curl"
        no_network.write_text(
            "#!/bin/sh\necho network-used >&2\nexit 99\n", encoding="utf-8"
        )
        no_network.chmod(0o755)
        env = {
            **os.environ,
            "CODEX_HOME": str(codez_home),
            "CODEX_INSTALL_DIR": str(public_bin),
            "PATH": f"{fake_bin}:/usr/bin:/bin",
        }
        return subprocess.run(
            [str(INSTALLER), "--bundle", str(bundle)],
            capture_output=True,
            text=True,
            env=env,
        )

    def _write_assets(self, assets: Path) -> None:
        checksums: list[str] = []
        for _system, _machine, target, is_linux in TARGETS:
            archive_path = assets / f"codez-package-{target}.tar.gz"
            files = {
                "bin/codez": f"#!/bin/sh\nprintf 'codez {VERSION}\\n'\n".encode(),
                "bin/codex-code-mode-host": b"#!/bin/sh\nexit 0\n",
                "codex-path/rg": b"#!/bin/sh\nexit 0\n",
                "codex-package.json": (
                    f'{{"version":"{VERSION}","variant":"codez"}}\n'.encode()
                ),
            }
            if is_linux:
                files["codex-resources/bwrap"] = b"#!/bin/sh\nexit 0\n"
            with tarfile.open(archive_path, "w:gz") as archive:
                for name, contents in files.items():
                    info = tarfile.TarInfo(name)
                    info.mode = (
                        0o755
                        if name.startswith(("bin/", "codex-path/", "codex-resources/"))
                        else 0o644
                    )
                    info.size = len(contents)
                    archive.addfile(info, io.BytesIO(contents))
            checksums.append(
                f"{hashlib.sha256(archive_path.read_bytes()).hexdigest()}  {archive_path.name}"
            )
        (assets / "codez-package_SHA256SUMS").write_text(
            "\n".join(checksums) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    unittest.main()
