//! `clipkitty secrets` — resolve App Store Connect auth fields for CI and
//! release orchestration. Internal release/sign code also calls
//! [`read_secret`] directly to decrypt other age-encrypted secrets.

use std::env;
use std::fs::File;
use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};

use crate::cli::{AscAuthArgs, SecretsCmd};
use crate::model::{AscAuthField, SideEffectLevel};
use crate::output::Reporter;
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

/// Resolve an age-encrypted secret to plaintext. With `$AGE_SECRET_KEY` set
/// (CI), decrypt with the `age` CLI; otherwise hand the whole job to
/// `keytap decrypt`, so the derived age identity never enters this process.
/// Prompt-freedom is keytap's job: after a one-time `keytap remember
/// clipkitty`, decrypts stop prompting on this machine; without it, every
/// decrypt is its own passkey ceremony.
pub(crate) fn read_secret(secret_path: &Utf8Path, reporter: &Reporter) -> Result<Vec<u8>> {
    if let Ok(key) = env::var("AGE_SECRET_KEY") {
        if !key.is_empty() {
            return age_decrypt(&key, secret_path);
        }
    }
    keytap_decrypt(secret_path, reporter)
}

fn keytap_decrypt(secret_path: &Utf8Path, reporter: &Reporter) -> Result<Vec<u8>> {
    if !tool_exists("keytap") {
        return Err(anyhow!(
            "neither AGE_SECRET_KEY nor the keytap CLI is available to decrypt {secret_path}"
        ));
    }
    reporter.info(&format!("Decrypting {secret_path} with keytap"));
    let file = File::open(secret_path.as_std_path())
        .with_context(|| format!("opening {secret_path}"))?;
    let output = Command::new("keytap")
        .args(["decrypt", "clipkitty"])
        .stdin(Stdio::from(file))
        .stdout(Stdio::piped())
        // The passkey ceremony (Touch ID notice, nearby-flow QR) renders on
        // stderr; it must reach the user.
        .stderr(Stdio::inherit())
        .output()
        .context("spawning keytap decrypt")?;
    if !output.status.success() {
        return Err(anyhow!("keytap decrypt failed for {secret_path}"));
    }
    Ok(output.stdout)
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
            let bytes = read_secret(&path, reporter)?;
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
