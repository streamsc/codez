#!/usr/bin/env python3
"""Build a deterministic multi-platform Codez offline installation bundle."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import re
import shutil
import tarfile
import tempfile
from pathlib import Path


TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
)
TAG_PATTERN = re.compile(r"^codez-v[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$")
CHECKSUM_PATTERN = re.compile(r"^([0-9a-fA-F]{64})  (.+)$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--asset-dir", type=Path, required=True)
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        match = CHECKSUM_PATTERN.fullmatch(line)
        if match is None:
            raise RuntimeError(f"Invalid checksum line in {path}: {line}")
        digest, name = match.groups()
        if name in checksums:
            raise RuntimeError(f"Duplicate checksum entry in {path}: {name}")
        checksums[name] = digest.lower()
    return checksums


def normalized_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    return info


def write_bundle(root: Path, output: Path) -> None:
    with output.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(
                fileobj=compressed, mode="w", format=tarfile.GNU_FORMAT
            ) as archive:
                archive.add(
                    root,
                    arcname=root.name,
                    recursive=True,
                    filter=normalized_tar_info,
                )


def main() -> int:
    args = parse_args()
    if not TAG_PATTERN.fullmatch(args.release_tag):
        raise RuntimeError(f"Invalid Codez release tag: {args.release_tag}")

    asset_dir = args.asset_dir.resolve()
    installer = args.installer.resolve()
    checksums_path = asset_dir / "codez-package_SHA256SUMS"
    if not asset_dir.is_dir():
        raise RuntimeError(f"Asset directory does not exist: {asset_dir}")
    if not installer.is_file():
        raise RuntimeError(f"Offline installer does not exist: {installer}")
    if not checksums_path.is_file():
        raise RuntimeError(f"Checksum manifest does not exist: {checksums_path}")

    checksums = read_checksums(checksums_path)
    assets = {
        target: asset_dir / f"codez-package-{target}.tar.gz" for target in TARGETS
    }
    for target, path in assets.items():
        if not path.is_file():
            raise RuntimeError(f"Missing package for {target}: {path}")
        expected = checksums.get(path.name)
        actual = sha256(path)
        if expected != actual:
            raise RuntimeError(
                f"Checksum mismatch for {path.name}: expected {expected}, got {actual}"
            )

    output = args.output.resolve()
    if output.exists():
        if not args.force:
            raise RuntimeError(f"Bundle output already exists: {output}")
        output.unlink()
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="codez-offline-bundle-") as temp_dir:
        bundle_version = args.release_tag.removeprefix("codez-")
        root = Path(temp_dir) / f"codez-offline-{bundle_version}"
        root.mkdir()
        shutil.copyfile(installer, root / "install-codez-offline.sh")
        (root / "install-codez-offline.sh").chmod(0o755)
        shutil.copyfile(checksums_path, root / checksums_path.name)
        manifest_lines = [
            "formatVersion=1",
            f"releaseTag={args.release_tag}",
        ]
        for target, path in assets.items():
            shutil.copyfile(path, root / path.name)
            manifest_lines.append(f"asset.{target}={path.name}")
        (root / "codez-offline-manifest").write_text(
            "\n".join(manifest_lines) + "\n", encoding="utf-8"
        )
        write_bundle(root, output)

    print(f"Built Codez offline bundle at {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
