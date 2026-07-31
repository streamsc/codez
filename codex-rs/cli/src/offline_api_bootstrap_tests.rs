use super::validate_api_base_url;
use pretty_assertions::assert_eq;

#[test]
fn validates_openai_compatible_base_urls() {
    assert_eq!(
        validate_api_base_url(" https://gateway.internal/v1 ").unwrap(),
        "https://gateway.internal/v1"
    );
}

#[test]
fn rejects_unsafe_or_incomplete_base_urls() {
    for (value, message) in [
        ("", "--api-base-url must not be empty"),
        (
            "ftp://gateway.internal/v1",
            "--api-base-url must use http or https",
        ),
        ("https:///v1", "--api-base-url must include a host"),
        (
            "https://user:pass@gateway.internal/v1",
            "--api-base-url must not contain user credentials",
        ),
    ] {
        let error = validate_api_base_url(value).expect_err("URL should be rejected");
        assert!(error.to_string().contains(message), "{error}");
    }
}
