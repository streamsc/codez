use pretty_assertions::assert_eq;
use std::path::Path;

use super::ExecutableIdentity;
use super::executable_identity;
use super::managed_codex_bin;
use super::parse_codex_version;

#[test]
fn managed_binary_uses_codez_private_install_root() {
    assert_eq!(
        managed_codex_bin(Path::new("/tmp/.codex")),
        Path::new("/tmp/.codex/packages/codez-app-server-daemon/current/bin/codez")
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

#[tokio::test]
async fn executable_identity_uses_binary_contents() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let executable = directory.path().join("codez");
    // Span multiple reads, including a partial final buffer, and preserve the
    // digest stored by older clients that hashed the complete file in memory.
    let mut bytes: Vec<u8> = (0..200_003).map(|index| (index % 251) as u8).collect();
    for contents in [&bytes[..], &[][..]] {
        std::fs::write(&executable, contents).expect("write executable");
        assert_eq!(
            executable_identity(&executable).await.expect("identity"),
            ExecutableIdentity {
                digest: *blake3::hash(contents).as_bytes(),
            }
        );
    }
    std::fs::write(&executable, &bytes).expect("write executable");
    let old = executable_identity(&executable).await.expect("identity");
    bytes[100_000] ^= 1;
    std::fs::write(&executable, bytes).expect("replace executable");
    assert_ne!(
        executable_identity(&executable)
            .await
            .expect("new identity"),
        old
    );
}
