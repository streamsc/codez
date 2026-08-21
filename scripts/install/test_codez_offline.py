#!/usr/bin/env python3

import hashlib
import io
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "scripts/install/install-codez-offline.sh"
BUILDER = REPO_ROOT / "scripts/build_codez_offline_bundle.py"
TAG = "codez-v0.144.4-r1"
VERSION = "0.144.4-r1"
UPSTREAM_VERSION = "0.144.4"
TARGETS = (
    ("Darwin", "arm64", "aarch64-apple-darwin", False),
    ("Darwin", "x86_64", "x86_64-apple-darwin", False),
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
                "Darwin",
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
            archive_path = bundle_dir / "codez-package-x86_64-apple-darwin.tar.gz"
            archive_path.write_bytes(archive_path.read_bytes() + b"corruption")

            failed = self._run_installer(
                bundle_dir,
                root / "codex-home",
                root / "bin",
                "Darwin",
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
            (bundle_dir / "codez-package-x86_64-apple-darwin.tar.gz").unlink()
            failed_asset = self._run_installer(
                bundle_dir,
                root / "asset-home",
                root / "asset-bin",
                "Darwin",
                "x86_64",
            )
            self.assertNotEqual(failed_asset.returncode, 0)
            self.assertIn(
                "Bundle is missing codez-package-x86_64-apple-darwin.tar.gz",
                failed_asset.stderr,
            )

    def test_configures_internal_api_without_exposing_key_to_child_arguments(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bundle_dir = self._build_extracted_bundle(root)
            codez_home = root / "codex-home"
            public_bin = root / "bin"
            secret = "sk-offline-secret"

            result = self._run_installer(
                bundle_dir,
                codez_home,
                public_bin,
                "Linux",
                "x86_64",
                extra_args=(
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--api-key",
                    secret,
                    "--model",
                    "internal-model",
                ),
                shell_xtrace=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(secret, result.stdout)
            self.assertNotIn(secret, result.stderr)
            self.assertIn(
                "--api-key can be exposed by shell history and process listings",
                result.stderr,
            )
            self.assertIn(
                "==> Configured API endpoint: https://gateway.internal/v1",
                result.stdout,
            )
            self.assertIn("==> Configured default model: internal-model", result.stdout)
            child_args = (codez_home / "bootstrap-args").read_text(encoding="utf-8")
            self.assertNotIn(secret, child_args)
            self.assertEqual(
                child_args.splitlines(),
                [
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--model",
                    "internal-model",
                ],
            )
            self.assertEqual(
                (codez_home / "bootstrap-key").read_text(encoding="utf-8"), secret
            )
            auth_path = codez_home / "auth.json"
            self.assertEqual(stat.S_IMODE(auth_path.stat().st_mode), 0o600)
            self.assertNotIn("network-used", result.stderr)

    def test_http_api_warns_and_model_is_optional(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bundle_dir = self._build_extracted_bundle(root)
            codez_home = root / "codex-home"
            result = self._run_installer(
                bundle_dir,
                codez_home,
                root / "bin",
                "Linux",
                "x86_64",
                extra_args=(
                    "--api-base-url",
                    "http://gateway.internal/v1",
                    "--api-key",
                    "sk-test",
                ),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "API key will be transmitted over unencrypted HTTP",
                result.stderr,
            )
            self.assertNotIn("Configured default model", result.stdout)
            self.assertNotIn("--model", (codez_home / "bootstrap-args").read_text())

    def test_api_argument_validation_happens_before_bundle_access(self) -> None:
        cases = (
            (
                ("--api-base-url", "https://gateway.internal/v1"),
                "--api-key is required",
            ),
            (("--api-key", "sk-test"), "--api-base-url is required"),
            (("--model", "internal-model"), "--api-base-url is required"),
            (
                (
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--api-key",
                    "",
                ),
                "--api-key must not be empty",
            ),
            (
                ("--api-base-url", "", "--api-key", "sk-test"),
                "--api-base-url must not be empty",
            ),
            (
                (
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--api-key",
                    "sk-test",
                    "--model",
                    "",
                ),
                "--model must not be empty",
            ),
            (("--bundle", "duplicate-bundle"), "--bundle may only be specified once"),
            (
                (
                    "--api-base-url",
                    "https://one.internal/v1",
                    "--api-base-url",
                    "https://two.internal/v1",
                ),
                "--api-base-url may only be specified once",
            ),
            (
                (
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--api-key",
                    "sk-one",
                    "--api-key",
                    "sk-two",
                ),
                "--api-key may only be specified once",
            ),
            (
                (
                    "--api-base-url",
                    "https://gateway.internal/v1",
                    "--api-key",
                    "sk-test",
                    "--model",
                    "model-one",
                    "--model",
                    "model-two",
                ),
                "--model may only be specified once",
            ),
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for index, (extra_args, expected) in enumerate(cases):
                with self.subTest(expected=expected):
                    result = self._run_installer(
                        root / "missing-bundle",
                        root / f"home-{index}",
                        root / f"bin-{index}",
                        "Linux",
                        "x86_64",
                        extra_args=extra_args,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)

    def test_bootstrap_failures_restore_same_version_install_config_and_auth(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            old_bundle = self._build_extracted_bundle(root / "old", generation="old")
            new_bundle = self._build_extracted_bundle(root / "new", generation="new")
            codez_home = root / "codex-home"
            public_bin = root / "bin"

            installed = self._run_installer(
                old_bundle,
                codez_home,
                public_bin,
                "Linux",
                "x86_64",
            )
            self.assertEqual(installed.returncode, 0, installed.stderr)
            config_path = codez_home / "config.toml"
            auth_path = codez_home / "auth.json"
            config_path.write_text('approval_policy = "never"\n', encoding="utf-8")
            auth_path.write_text(
                '{"auth_mode":"api_key","OPENAI_API_KEY":"sk-old"}\n',
                encoding="utf-8",
            )
            auth_path.chmod(0o600)
            current = codez_home / "packages/codez/current"
            previous_current = os.readlink(current)
            previous_binary = (current / "bin/codez").read_bytes()
            previous_config = config_path.read_bytes()
            previous_auth = auth_path.read_bytes()

            for failure_mode in ("config", "auth"):
                with self.subTest(failure_mode=failure_mode):
                    failed = self._run_installer(
                        new_bundle,
                        codez_home,
                        public_bin,
                        "Linux",
                        "x86_64",
                        extra_args=(
                            "--api-base-url",
                            "https://gateway.internal/v1",
                            "--api-key",
                            "sk-new-secret",
                        ),
                        extra_env={"CODEZ_TEST_BOOTSTRAP_FAIL": failure_mode},
                    )

                    self.assertNotEqual(failed.returncode, 0)
                    self.assertNotIn("sk-new-secret", failed.stdout + failed.stderr)
                    self.assertEqual(os.readlink(current), previous_current)
                    self.assertEqual(
                        (current / "bin/codez").read_bytes(), previous_binary
                    )
                    self.assertEqual(config_path.read_bytes(), previous_config)
                    self.assertEqual(auth_path.read_bytes(), previous_auth)

    def _build_extracted_bundle(
        self, root: Path, *, generation: str = "default"
    ) -> Path:
        root.mkdir(parents=True, exist_ok=True)
        assets = root / "assets"
        assets.mkdir()
        self._write_assets(assets, generation=generation)
        bundle = root / "bundle.tar.gz"
        self._build_bundle(assets, bundle)
        extracted = root / "extracted"
        extracted.mkdir()
        with tarfile.open(bundle, "r:gz") as archive:
            archive.extractall(extracted)
        return next(extracted.iterdir())

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
        extra_args: tuple[str, ...] = (),
        extra_env: dict[str, str] | None = None,
        shell_xtrace: bool = False,
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
        if extra_env is not None:
            env.update(extra_env)
        command = [str(INSTALLER), "--bundle", str(bundle), *extra_args]
        if shell_xtrace:
            command = ["sh", "-x", *command]
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            env=env,
        )

    def _write_assets(self, assets: Path, *, generation: str = "default") -> None:
        checksums: list[str] = []
        for _system, _machine, target, is_linux in TARGETS:
            archive_path = assets / f"codez-package-{target}.tar.gz"
            codez_script = f"""#!/bin/sh
# generation: {generation}
case "$1" in
  --version)
    printf 'codez {VERSION}\\n'
    ;;
  offline-api-bootstrap)
    shift
    mkdir -p "$CODEX_HOME"
    : >"$CODEX_HOME/bootstrap-args"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >>"$CODEX_HOME/bootstrap-args"
    done
    IFS= read -r api_key || true
    printf '%s' "$api_key" >"$CODEX_HOME/bootstrap-key"
    if [ "${{CODEZ_TEST_BOOTSTRAP_FAIL:-}}" = config ]; then
      printf '%s\\n' 'bootstrap = "partial"' >>"$CODEX_HOME/config.toml"
      echo 'simulated config failure' >&2
      exit 70
    fi
    printf '%s\\n' 'bootstrap = "configured"' >>"$CODEX_HOME/config.toml"
    if [ "${{CODEZ_TEST_BOOTSTRAP_FAIL:-}}" = auth ]; then
      printf '{{"auth_mode":"api_key","OPENAI_API_KEY":"partial"}}\\n' >"$CODEX_HOME/auth.json"
      chmod 0600 "$CODEX_HOME/auth.json"
      echo 'simulated auth failure' >&2
      exit 71
    fi
    printf '{{"auth_mode":"api_key","OPENAI_API_KEY":"%s"}}\\n' "$api_key" >"$CODEX_HOME/auth.json"
    chmod 0600 "$CODEX_HOME/auth.json"
    echo 'Successfully logged in' >&2
    ;;
  *)
    exit 64
    ;;
esac
"""
            files = {
                "bin/codez": codez_script.encode(),
                "bin/codex-code-mode-host": b"#!/bin/sh\nexit 0\n",
                "codex-path/rg": b"#!/bin/sh\nexit 0\n",
                "codex-package.json": (
                    f'{{"version":"{UPSTREAM_VERSION}","variant":"codez"}}\n'.encode()
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
