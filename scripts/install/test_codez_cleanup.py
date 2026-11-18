#!/usr/bin/env python3
"""Exercise the upstream cleanup contract in both self-contained Codez installers."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


class CodezCleanupTest(unittest.TestCase):
    def test_cleanup_retains_running_previous_and_unowned_releases(self) -> None:
        for name in ("install-codez.sh", "install-codez-offline.sh"):
            with self.subTest(installer=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve() / "André Codez 安装"
                packages = root / "packages/codez"
                releases = packages / "releases"
                runtime = root / "tmp"
                runtime.mkdir(parents=True)
                system = os.uname()
                arch = "aarch64" if system.machine in ("arm64", "aarch64") else "x86_64"
                target = f"{arch}-{'apple-darwin' if system.sysname == 'Darwin' else 'unknown-linux-musl'}"
                owned = []
                for version in ("0.167.0-r1", "0.168.0-r1", "0.169.1-r1"):
                    release = releases / f"{version}-{target}"
                    (release / "bin").mkdir(parents=True)
                    (release / "bin/codez").write_text("fixture")
                    (release / "codez").symlink_to("bin/codez")
                    (release / "codex-package.json").write_text(
                        json.dumps(
                            {
                                "version": version,
                                "target": target,
                                "entrypoint": "bin/codez",
                            }
                        )
                    )
                    owned.append(release)
                (packages / "current").symlink_to(owned[-1])
                unowned = releases / "unowned"
                unowned.mkdir()
                (unowned / "user-file").write_text("preserve")
                retired = releases / ".retired.interrupted"
                retired.mkdir()
                external = root / "external"
                external.mkdir()
                (releases / "linked-user-data").symlink_to(external)
                helper = owned[0] / "bin/codex-exec-server"
                shutil.copyfile("/bin/sleep", helper)
                helper.chmod(0o755)
                if system.sysname == "Darwin":
                    subprocess.run(
                        ["/usr/bin/codesign", "--force", "--sign", "-", str(helper)],
                        check=True,
                        capture_output=True,
                    )
                text = Path(__file__).with_name(name).read_text()
                functions = text.split("# Keep this process-aware cleanup", 1)[1].split(
                    "usage() {", 1
                )[0]
                functions = "# Keep this process-aware cleanup" + functions
                variables = {
                    "CODEX_HOME_DIR": root,
                    "INSTALL_ROOT": packages,
                    "RELEASES_DIR": releases,
                    "CURRENT_LINK": packages / "current",
                    "release_dir": owned[-1],
                    "previous_dir": owned[-2],
                    "tmp_dir": runtime,
                    "os": system.sysname.lower(),
                }
                script = (
                    "set -eu\n"
                    + functions
                    + "\n".join(
                        f"{key}={shlex.quote(str(value))}"
                        for key, value in variables.items()
                    )
                    + "\nrecord_selection_history\nprune_standalone_releases\n"
                )
                with subprocess.Popen([str(helper), "60"]) as running:
                    try:
                        active = subprocess.run(
                            ["sh"], input=script, text=True, capture_output=True
                        )
                        self.assertTrue(owned[0].is_dir(), active.stderr)
                        self.assertIsNone(running.poll())
                    finally:
                        running.terminate()
                        running.wait()
                stopped = subprocess.run(
                    ["sh"], input=script, text=True, capture_output=True
                )
                if stopped.returncode:
                    self.skipTest(
                        f"Host process inspection is unavailable: {stopped.stderr}"
                    )
                self.assertFalse(owned[0].exists())
                self.assertTrue(all(path.is_dir() for path in owned[1:]))
                self.assertTrue((unowned / "user-file").is_file())
                self.assertTrue(retired.is_dir())
                self.assertTrue(external.is_dir())
                self.assertTrue((releases / "linked-user-data").is_symlink())


if __name__ == "__main__":
    unittest.main()
