//! `clipkitty secrets` — resolve App Store Connect auth fields for CI and
//! release orchestration. Internal release/sign code also calls
//! [`read_secret`] directly to decrypt other age-encrypted secrets.

use std::env;
use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};

use crate::cli::{AscAuthArgs, SecretsCmd};
use crate::model::{AscAuthField, SideEffectLevel};
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(cmd: &SecretsCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::Credentialed;
    let repo = RepoRoot::discover(reporter)?;
    match cmd {
        SecretsCmd::AscAuth(args) => asc_auth(&repo, args, dry_run, reporter),
    }
}

fn secret_path(repo: &RepoRoot, name: &str) -> Utf8PathBuf {
    let stem = name.strip_suffix(".age").unwrap_or(name);
    repo.join(format!("secrets/{stem}.age"))
}

/// Resolve an age-encrypted secret to plaintext, mirroring the keytap +
/// keychain + `$AGE_SECRET_KEY` fallback used by the existing signing/release
/// flows.
pub(crate) fn read_secret(
    repo: &RepoRoot,
    secret_path: &Utf8Path,
    reporter: &Reporter,
) -> Result<Vec<u8>> {
    match age_identity_source(repo)? {
        AgeIdentitySource::EnvVar(key) => age_decrypt(&key, secret_path),
        AgeIdentitySource::Keychain { account } => match read_keychain(&account) {
            Some(key) => match age_decrypt(&key, secret_path) {
                Ok(bytes) => Ok(bytes),
                Err(_) => fallback_to_keytap(&account, secret_path, reporter),
            },
            None => fallback_to_keytap(&account, secret_path, reporter),
        },
    }
}

enum AgeIdentitySource {
    EnvVar(String),
    Keychain { account: String },
}

fn age_identity_source(repo: &RepoRoot) -> Result<AgeIdentitySource> {
    if let Ok(key) = env::var("AGE_SECRET_KEY") {
        if !key.is_empty() {
            return Ok(AgeIdentitySource::EnvVar(key));
        }
    }
    let project_name = repo
        .as_path()
        .file_name()
        .ok_or_else(|| anyhow!("repo root has no filename"))?
        .to_owned();
    Ok(AgeIdentitySource::Keychain {
        account: format!("AGE_SECRET_KEY_{project_name}"),
    })
}

fn read_keychain(account: &str) -> Option<String> {
    let output = Command::new("security")
        .args(["find-generic-password", "-s", "keytap", "-a", account, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let raw = String::from_utf8(output.stdout).ok()?;
    let trimmed = raw.trim_end_matches('\n').to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn cache_keychain(account: &str, key: &str) {
    let _ = Command::new("security")
        .args([
            "add-generic-password",
            "-U",
            "-s",
            "keytap",
            "-a",
            account,
            "-w",
            key,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn fallback_to_keytap(
    account: &str,
    secret_path: &Utf8Path,
    reporter: &Reporter,
) -> Result<Vec<u8>> {
    if !tool_exists("keytap") {
        return Err(anyhow!(
            "Neither AGE_SECRET_KEY, keychain, nor keytap available to decrypt {secret_path}"
        ));
    }
    let out = Runner::new(reporter, "keytap")
        .args(["reveal", "clipkitty", "--format", "age"])
        .output()?;
    let key = out.stdout_string()?.trim().to_string();
    let plaintext = age_decrypt(&key, secret_path)?;
    cache_keychain(account, &key);
    Ok(plaintext)
}

fn age_decrypt(identity: &str, secret_path: &Utf8Path) -> Result<Vec<u8>> {
    let mut child = Command::new("age")
        .arg("-d")
        .arg("-i")
        .arg("-")
        .arg(secret_path.as_std_path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning age")?;
    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow!("age stdin closed"))?;
        stdin
            .write_all(identity.as_bytes())
            .context("writing age identity")?;
    }
    let output = child.wait_with_output().context("waiting for age")?;
    if !output.status.success() {
        return Err(anyhow!(
            "age -d exited with status {:?}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(output.stdout)
}

fn asc_auth(repo: &RepoRoot, args: &AscAuthArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would resolve ASC field {:?}",
            args.field
        ));
        return Ok(());
    }

    let value = resolve_asc_field(repo, args.field, reporter)?;
    println!("{value}");
    Ok(())
}

pub(crate) fn resolve_asc_field(
    repo: &RepoRoot,
    field: AscAuthField,
    reporter: &Reporter,
) -> Result<String> {
    let (primary, fallback) = match field {
        AscAuthField::KeyId => ("APPSTORE_KEY_ID", "NOTARY_KEY_ID"),
        AscAuthField::IssuerId => ("APPSTORE_ISSUER_ID", "NOTARY_ISSUER_ID"),
        AscAuthField::PrivateKeyB64 => ("APPSTORE_KEY_BASE64", "NOTARY_KEY_BASE64"),
    };
    for name in [primary, fallback] {
        let path = secret_path(repo, name);
        if path.as_std_path().is_file() {
            let bytes = read_secret(repo, &path, reporter)?;
            return Ok(String::from_utf8(bytes)
                .context("ASC secret is not UTF-8")?
                .trim()
                .to_string());
        }
    }
    Err(anyhow!(
        "neither {primary}.age nor {fallback}.age was found in secrets/"
    ))
}

fn tool_exists(name: &str) -> bool {
    Command::new("which")
        .arg(name)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
