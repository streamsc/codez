use anyhow::Context;
use anyhow::Result;
use clap::Parser;
use codex_core::config::ConfigBuilder;
use codex_core::config::edit::ConfigEditsBuilder;
use codex_login::login_with_api_key;
use codex_protocol::config_types::ForcedLoginMethod;
use codex_utils_cli::CliConfigOverrides;
use url::Url;

use codex_cli::read_api_key_from_stdin;

#[derive(Debug, Parser)]
pub(crate) struct Command {
    /// Full OpenAI-compatible API root, such as https://host/v1.
    #[arg(long = "api-base-url", value_name = "URL")]
    pub(crate) api_base_url: String,

    /// Optional default model for new sessions.
    #[arg(long = "model", value_name = "MODEL")]
    pub(crate) model: Option<String>,

    #[clap(skip)]
    pub(crate) config_overrides: CliConfigOverrides,
}

pub(crate) async fn run(command: Command) -> Result<()> {
    let api_base_url = validate_api_base_url(&command.api_base_url)?;
    let model_was_provided = command.model.is_some();
    let model = command
        .model
        .map(|model| model.trim().to_string())
        .filter(|model| !model.is_empty());
    if model_was_provided && model.is_none() {
        anyhow::bail!("--model must not be empty");
    }

    let cli_overrides = command
        .config_overrides
        .parse_overrides()
        .map_err(anyhow::Error::msg)?;
    let config = ConfigBuilder::default()
        .cli_overrides(cli_overrides)
        .build()
        .await
        .context("failed to load Codez configuration")?;

    if matches!(config.forced_login_method, Some(ForcedLoginMethod::Chatgpt)) {
        anyhow::bail!("offline API bootstrap is disabled when login method is forced to ChatGPT");
    }

    let api_key = read_api_key_from_stdin();

    let mut edits = ConfigEditsBuilder::new(config.codex_home.as_path())
        .set_openai_base_url(&api_base_url)
        .set_model_provider("openai");
    if let Some(model) = model.as_deref() {
        edits = edits.set_model_name(model);
    }
    edits
        .apply()
        .await
        .context("failed to save offline API configuration")?;

    login_with_api_key(
        config.codex_home.as_path(),
        &api_key,
        config.cli_auth_credentials_store_mode,
        config.auth_keyring_backend_kind(),
    )
    .context("failed to save offline API credentials")?;

    println!("Configured OpenAI-compatible API endpoint: {api_base_url}");
    if let Some(model) = model {
        println!("Configured default model: {model}");
    }
    Ok(())
}

fn validate_api_base_url(raw: &str) -> Result<String> {
    let value = raw.trim();
    if value.is_empty() {
        anyhow::bail!("--api-base-url must not be empty");
    }

    let url = Url::parse(value).map_err(|error| match error {
        url::ParseError::EmptyHost => anyhow::anyhow!("--api-base-url must include a host"),
        error => anyhow::anyhow!("--api-base-url must be a valid URL: {error}"),
    })?;
    if !matches!(url.scheme(), "http" | "https") {
        anyhow::bail!("--api-base-url must use http or https");
    }
    if url.host_str().is_none() {
        anyhow::bail!("--api-base-url must include a host");
    }
    if !url.username().is_empty() || url.password().is_some() {
        anyhow::bail!("--api-base-url must not contain user credentials");
    }

    Ok(value.to_string())
}

#[cfg(test)]
#[path = "offline_api_bootstrap_tests.rs"]
mod tests;
