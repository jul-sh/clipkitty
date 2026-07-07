//! `clipkitty secrets` — resolve App Store Connect auth fields for CI and
//! release orchestration. Internal release/sign code also calls
//! [`read_secret`] directly to decrypt other age-encrypted secrets.

use std::fs::File;
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

/// Resolve an age-encrypted secret to plaintext with `keytap decrypt
/// clipkitty` — the same command everywhere, so the derived age identity
/// never enters this process. Prompt-freedom is keytap's job: in CI,
/// `$KEYTAP_KEY_CLIPKITTY` carries the derived key and keytap never prompts
/// (it refuses ceremonies under `$CI`); on a dev machine, a one-time
/// `keytap remember clipkitty` makes decrypts prompt-free, and without it
/// every decrypt is its own passkey ceremony.
pub(crate) fn read_secret(secret_path: &Utf8Path, _reporter: &Reporter) -> Result<Vec<u8>> {
    if !tool_exists("keytap") {
        return Err(anyhow!(
            "the keytap CLI is not available to decrypt {secret_path} (install keytap, then \
             set $KEYTAP_KEY_CLIPKITTY in CI or run `keytap remember clipkitty` on this machine)"
        ));
    }
    // stderr, never the Reporter: callers pipe this command's stdout as data
    // (`secrets-asc-auth | base64 -d`), so stdout must carry only the secret.
    eprintln!("Decrypting {secret_path} with keytap");
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
