use pretty_assertions::assert_eq;
use std::path::Path;

use super::executable_identity_from_bytes;
use super::managed_codex_bin;
use super::parse_codex_version;

#[test]
fn managed_binary_uses_codez_private_install_root() {
    assert_eq!(
        managed_codex_bin(Path::new("/tmp/.codex")),
        Path::new("/tmp/.codex/packages/codez/current/bin/codez")
    );
}

#[test]
fn parses_codex_cli_version_output() {
    assert_eq!(
        parse_codex_version("codez 1.2.3-r4\n").expect("version"),
        "1.2.3-r4"
    );
    assert_eq!(
        parse_codex_version("codez 1.2.3\n").expect("version"),
        "1.2.3"
    );
}

#[test]
fn rejects_malformed_codex_cli_version_output() {
    assert!(parse_codex_version("codez\n").is_err());
}

#[test]
fn executable_identity_uses_binary_contents() {
    let old = executable_identity_from_bytes(b"old");
    let same = executable_identity_from_bytes(b"old");
    let new = executable_identity_from_bytes(b"new");

    assert_eq!(old, same);
    assert_ne!(old, new);
}
