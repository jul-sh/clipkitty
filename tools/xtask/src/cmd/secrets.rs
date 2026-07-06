//! `clipkitty secrets` — resolve App Store Connect auth fields for CI and
//! release orchestration. Internal release/sign code also calls
//! [`read_secret`] directly to decrypt other age-encrypted secrets.

use std::env;
use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::OnceLock;

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

/// Resolve an age-encrypted secret to plaintext. The age identity comes from
/// `$AGE_SECRET_KEY` (CI) or `keytap reveal` (local development). Key
/// persistence is keytap's job: `keytap remember clipkitty` makes reveals
/// prompt-free on this machine.
pub(crate) fn read_secret(secret_path: &Utf8Path, reporter: &Reporter) -> Result<Vec<u8>> {
    let identity = age_identity(reporter)
        .with_context(|| format!("resolving age identity to decrypt {secret_path}"))?;
    age_decrypt(&identity, secret_path)
}

/// Key revealed by keytap during this run, so commands that decrypt several
/// secrets (e.g. signing setup) invoke keytap at most once.
static REVEALED_KEY: OnceLock<String> = OnceLock::new();

fn age_identity(reporter: &Reporter) -> Result<String> {
    if let Ok(key) = env::var("AGE_SECRET_KEY") {
        if !key.is_empty() {
            return Ok(key);
        }
    }
    if let Some(key) = REVEALED_KEY.get() {
        return Ok(key.clone());
    }
    if !tool_exists("keytap") {
        return Err(anyhow!(
            "neither AGE_SECRET_KEY nor the keytap CLI is available"
        ));
    }
    let out = Runner::new(reporter, "keytap")
        .args(["reveal", "clipkitty", "--format", "age"])
        .output()?;
    let key = out.stdout_string()?.trim().to_string();
    if key.is_empty() {
        return Err(anyhow!("keytap reveal produced an empty key"));
    }
    Ok(REVEALED_KEY.get_or_init(|| key).clone())
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
