use std::ffi::OsString;

use anyhow::{anyhow, Result};
use base64::Engine;

enum LookupResult {
    Present(String),
    Missing,
    NotUtf8,
}

impl LookupResult {
    fn from_raw(value: Option<OsString>) -> Self {
        match value {
            None => Self::Missing,
            Some(value) => match value.into_string() {
                Ok(value) if value.is_empty() => Self::Missing,
                Ok(value) => Self::Present(value),
                Err(_) => Self::NotUtf8,
            },
        }
    }
}

pub(crate) fn required(name: &str) -> Result<String> {
    required_with(name, |name| std::env::var_os(name))
}

pub(crate) fn required_base64(name: &str) -> Result<Vec<u8>> {
    required_base64_with(name, |name| std::env::var_os(name))
}

fn required_base64_with(
    name: &str,
    lookup: impl FnOnce(&str) -> Option<OsString>,
) -> Result<Vec<u8>> {
    let value = required_with(name, lookup)?;
    let compact: String = value
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(compact)
        .map_err(|error| anyhow!("decoding {name}: {error}"))
}

fn required_with(name: &str, lookup: impl FnOnce(&str) -> Option<OsString>) -> Result<String> {
    match LookupResult::from_raw(lookup(name)) {
        LookupResult::Present(value) => Ok(value),
        LookupResult::Missing => Err(anyhow!(
            "{name} is not set; run this command with `envtap run -- ...`"
        )),
        LookupResult::NotUtf8 => Err(anyhow!("{name} is not valid UTF-8")),
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{required_base64_with, required_with};

    #[test]
    fn returns_the_requested_value() {
        let value = required_with("TOKEN", |name| {
            assert_eq!(name, "TOKEN");
            Some(OsString::from("secret"))
        })
        .unwrap();

        assert_eq!(value, "secret");
    }

    #[test]
    fn missing_and_empty_values_explain_how_to_inject_the_environment() {
        for value in [None, Some(OsString::new())] {
            let error = required_with("TOKEN", |_| value).unwrap_err();
            assert_eq!(
                error.to_string(),
                "TOKEN is not set; run this command with `envtap run -- ...`"
            );
        }
    }

    #[test]
    fn decodes_whitespace_wrapped_base64() {
        let decoded =
            required_base64_with("CERT", |_| Some(OsString::from("aGVs\n bG8=\r\n"))).unwrap();

        assert_eq!(decoded, b"hello");
    }

    #[test]
    fn malformed_base64_names_the_variable() {
        let error =
            required_base64_with("CERT", |_| Some(OsString::from("not base64!"))).unwrap_err();

        assert!(error.to_string().starts_with("decoding CERT:"));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_non_utf8_values() {
        use std::os::unix::ffi::OsStringExt;

        let error = required_with("TOKEN", |_| Some(OsString::from_vec(vec![0xff]))).unwrap_err();

        assert_eq!(error.to_string(), "TOKEN is not valid UTF-8");
    }
}
