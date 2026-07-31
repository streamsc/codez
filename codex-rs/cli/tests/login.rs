#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::Context;
use anyhow::Result;
use codex_login::CLIENT_ID;
use codex_login::REVOKE_TOKEN_URL_OVERRIDE_ENV_VAR;
use predicates::prelude::PredicateBooleanExt;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use serde_json::Value;
use serde_json::json;
use tempfile::TempDir;
use wiremock::Mock;
use wiremock::MockServer;
use wiremock::ResponseTemplate;
use wiremock::matchers::method;
use wiremock::matchers::path;

fn codex_command(codex_home: &Path) -> Result<assert_cmd::Command> {
    let mut cmd = assert_cmd::Command::new(codex_utils_cargo_bin::cargo_bin("codex")?);
    cmd.env("CODEX_HOME", codex_home);
    Ok(cmd)
}

fn write_file_auth_config(codex_home: &Path) -> Result<()> {
    std::fs::write(
        codex_home.join("config.toml"),
        "cli_auth_credentials_store = \"file\"\n",
    )?;
    Ok(())
}

fn read_auth_json(codex_home: &Path) -> Result<Value> {
    let auth_json = std::fs::read_to_string(codex_home.join("auth.json"))?;
    Ok(serde_json::from_str(&auth_json)?)
}

#[test]
fn login_with_api_key_reads_stdin_and_writes_auth_json() -> Result<()> {
    let codex_home = TempDir::new()?;
    write_file_auth_config(codex_home.path())?;

    let mut cmd = codex_command(codex_home.path())?;
    cmd.args([
        "-c",
        "forced_login_method=\"api\"",
        "login",
        "--with-api-key",
    ])
    .write_stdin("sk-test\n")
    .assert()
    .success()
    .stderr(contains("Successfully logged in"));

    let auth = read_auth_json(codex_home.path())?;
    assert_eq!(auth["OPENAI_API_KEY"], "sk-test");
    assert!(auth.get("tokens").is_none());
    assert!(auth.get("agent_identity").is_none());

    Ok(())
}

#[test]
fn offline_api_bootstrap_writes_endpoint_model_and_api_key() -> Result<()> {
    let codex_home = TempDir::new()?;
    std::fs::write(
        codex_home.path().join("config.toml"),
        "# keep this comment\ncli_auth_credentials_store = \"file\"\nmodel = \"old-model\"\nmodel_reasoning_effort = \"high\"\napproval_policy = \"never\"\n",
    )?;
    let secret = "sk-offline-secret";

    let output = codex_command(codex_home.path())?
        .args([
            "offline-api-bootstrap",
            "--api-base-url",
            "https://gateway.internal/v1",
            "--model",
            "internal-model",
        ])
        .write_stdin(format!("{secret}\n"))
        .output()?;

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stdout.contains("https://gateway.internal/v1"));
    assert!(stdout.contains("internal-model"));
    assert!(!stdout.contains(secret));
    assert!(!stderr.contains(secret));

    let config_text = std::fs::read_to_string(codex_home.path().join("config.toml"))?;
    let _: toml::Value = toml::from_str(&config_text)?;
    assert!(config_text.contains("# keep this comment"));
    assert!(config_text.contains("openai_base_url = \"https://gateway.internal/v1\""));
    assert!(config_text.contains("model_provider = \"openai\""));
    assert!(config_text.contains("model = \"internal-model\""));
    assert!(config_text.contains("model_reasoning_effort = \"high\""));
    assert!(!config_text.contains(secret));

    let auth = read_auth_json(codex_home.path())?;
    assert_eq!(auth["OPENAI_API_KEY"], secret);
    #[cfg(unix)]
    assert_eq!(
        std::fs::metadata(codex_home.path().join("auth.json"))?
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    Ok(())
}

#[test]
fn offline_api_bootstrap_without_model_preserves_existing_model() -> Result<()> {
    let codex_home = TempDir::new()?;
    std::fs::write(
        codex_home.path().join("config.toml"),
        "cli_auth_credentials_store = \"file\"\nmodel = \"existing-model\"\n",
    )?;

    codex_command(codex_home.path())?
        .args([
            "offline-api-bootstrap",
            "--api-base-url",
            "http://gateway.internal/v1",
        ])
        .write_stdin("sk-test\n")
        .assert()
        .success()
        .stdout(contains("http://gateway.internal/v1"))
        .stdout(predicates::str::contains("default model").not());

    let config_text = std::fs::read_to_string(codex_home.path().join("config.toml"))?;
    let _: toml::Value = toml::from_str(&config_text)?;
    assert!(config_text.contains("model = \"existing-model\""));
    assert!(config_text.contains("model_provider = \"openai\""));
    Ok(())
}

#[test]
fn offline_api_bootstrap_rejects_invalid_url_and_empty_key() -> Result<()> {
    let invalid_url_home = TempDir::new()?;
    codex_command(invalid_url_home.path())?
        .args([
            "offline-api-bootstrap",
            "--api-base-url",
            "ftp://gateway.internal/v1",
        ])
        .write_stdin("sk-test\n")
        .assert()
        .failure()
        .stderr(contains("must use http or https"));
    assert!(!invalid_url_home.path().join("config.toml").exists());

    let empty_key_home = TempDir::new()?;
    codex_command(empty_key_home.path())?
        .args([
            "offline-api-bootstrap",
            "--api-base-url",
            "https://gateway.internal/v1",
        ])
        .write_stdin("\n")
        .assert()
        .failure()
        .stderr(contains("No API key provided via stdin"));
    assert!(!empty_key_home.path().join("config.toml").exists());
    Ok(())
}

#[test]
fn offline_api_bootstrap_respects_forced_chatgpt_login() -> Result<()> {
    let codex_home = TempDir::new()?;
    write_file_auth_config(codex_home.path())?;

    codex_command(codex_home.path())?
        .args([
            "-c",
            "forced_login_method=\"chatgpt\"",
            "offline-api-bootstrap",
            "--api-base-url",
            "https://gateway.internal/v1",
        ])
        .write_stdin("sk-test\n")
        .assert()
        .failure()
        .stderr(contains("forced to ChatGPT"));

    assert_eq!(
        std::fs::read_to_string(codex_home.path().join("config.toml"))?,
        "cli_auth_credentials_store = \"file\"\n"
    );
    assert!(!codex_home.path().join("auth.json").exists());
    Ok(())
}

#[test]
fn offline_api_bootstrap_is_hidden_from_normal_help() -> Result<()> {
    let codex_home = TempDir::new()?;
    let help = codex_command(codex_home.path())?
        .args(["--help"])
        .output()?;
    assert!(help.status.success());
    assert!(!String::from_utf8_lossy(&help.stdout).contains("offline-api-bootstrap"));

    codex_command(codex_home.path())?
        .args(["offline-api-bootstrap", "--help"])
        .assert()
        .success()
        .stdout(contains("--api-base-url"));
    Ok(())
}

#[test]
fn login_with_access_token_rejects_invalid_jwt() -> Result<()> {
    let codex_home = TempDir::new()?;
    write_file_auth_config(codex_home.path())?;

    let mut cmd = codex_command(codex_home.path())?;
    cmd.args(["login", "--with-access-token"])
        .write_stdin("not-a-jwt\n")
        .assert()
        .failure()
        .stderr(contains("Error logging in with access token"));

    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn device_login_revokes_existing_auth_before_requesting_new_tokens() -> Result<()> {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/oauth/revoke"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/api/accounts/deviceauth/usercode"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "device_auth_id": "device-auth-123",
            "user_code": "CODE-12345",
            "interval": "0",
        })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/api/accounts/deviceauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "authorization_code": "authorization-code-123",
            "code_challenge": "code-challenge-123",
            "code_verifier": "code-verifier-123",
        })))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/oauth/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id_token": "eyJhbGciOiJub25lIn0.e30.c2ln",
            "access_token": "new-access",
            "refresh_token": "new-refresh",
        })))
        .expect(1)
        .mount(&server)
        .await;

    let codex_home = TempDir::new()?;
    write_file_auth_config(codex_home.path())?;
    std::fs::write(
        codex_home.path().join("auth.json"),
        serde_json::to_vec(&json!({
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "eyJhbGciOiJub25lIn0.e30.c2ln",
                "access_token": "old-access",
                "refresh_token": "old-refresh",
                "account_id": "old-account",
            },
        }))?,
    )?;

    let issuer = server.uri();
    let mut cmd = codex_command(codex_home.path())?;
    cmd.env(
        REVOKE_TOKEN_URL_OVERRIDE_ENV_VAR,
        format!("{issuer}/oauth/revoke"),
    )
    .env("NO_PROXY", "127.0.0.1,localhost")
    .env("no_proxy", "127.0.0.1,localhost")
    .env_remove("CODEX_ACCESS_TOKEN")
    .env_remove("OPENAI_API_KEY")
    .args(["login", "--device-auth", "--experimental_issuer", &issuer])
    .assert()
    .success()
    .stderr(contains("Successfully logged in"));

    let requests = server
        .received_requests()
        .await
        .context("failed to read mock OAuth requests")?;
    let paths: Vec<&str> = requests.iter().map(|request| request.url.path()).collect();
    assert_eq!(
        paths,
        vec![
            "/oauth/revoke",
            "/api/accounts/deviceauth/usercode",
            "/api/accounts/deviceauth/token",
            "/oauth/token",
        ]
    );
    assert_eq!(
        requests[0]
            .body_json::<Value>()
            .context("revoke request should be JSON")?,
        json!({
            "token": "old-refresh",
            "token_type_hint": "refresh_token",
            "client_id": CLIENT_ID,
        })
    );

    let auth = read_auth_json(codex_home.path())?;
    assert_eq!(auth["tokens"]["refresh_token"], "new-refresh");
    Ok(())
}
