/// The current Codez CLI version as embedded at compile time.
pub const CODEX_CLI_VERSION: &str = match option_env!("CODEZ_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
