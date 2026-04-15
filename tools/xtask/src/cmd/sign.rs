//! `clipkitty sign` — codesign a previously-built ClipKitty bundle.
//!
//! Each supported variant carries a `SigningMode` plus the identity and
//! entitlements profile it needs. The command refuses to sign variants
//! (`Debug`, `Release`) that aren't valid codesign targets, making illegal
//! signing states unrepresentable.

use std::env;
use std::fs;

use anyhow::{anyhow, Result};
use base64::Engine;
use camino::Utf8PathBuf;
use tempfile::NamedTempFile;
use uuid::Uuid;

use crate::apple::{self, CodesignArgs};
use crate::cmd::build;
use crate::model::{MacVariant, SetupAction, SigningMode};
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SetupFlow {
    AppStore,
    Dev,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SetupRequest {
    pub flow: SetupFlow,
    pub action: SetupAction,
}

pub(crate) struct SignAppRequest {
    pub variant: MacVariant,
    pub version: Option<String>,
    pub build_number: Option<String>,
}

/// Resolved signing plan. The two variants carry structurally different
/// data — Developer ID needs `--timestamp` and never embeds a provisioning
/// profile; App Store is the opposite — so capturing this as an enum kills
/// the former `struct { identity, entitlements, include_timestamp: bool }` +
/// `if args.configuration == AppStore { ... }` combo, both of which were
/// parallel-boolean smells.
enum SigningPlan {
    DeveloperId {
        identity: String,
        entitlements: Utf8PathBuf,
        embeds_provisioning_profile: bool,
    },
    AppStore {
        identity: String,
        entitlements: Utf8PathBuf,
        /// Path to a `.provisionprofile` to embed before signing. Read once
        /// from $PROVISIONING_PROFILE at planning time; `None` means the
        /// caller expects the bundle to already carry one from an earlier
        /// step (CI flow).
        provisioning_profile: Option<Utf8PathBuf>,
    },
}

fn signing_plan(repo: &RepoRoot, variant: MacVariant) -> Result<SigningPlan> {
    let mode = variant
        .signing_mode()
        .ok_or_else(|| anyhow!("variant `{:?}` is not a codesign target", variant))?;
    match mode {
        SigningMode::DeveloperId => Ok(SigningPlan::DeveloperId {
            identity: env::var("SIGNING_IDENTITY")
                .unwrap_or_else(|_| "Developer ID Application".to_string()),
            entitlements: match variant {
                MacVariant::SparkleRelease => {
                    repo.join("Sources/MacApp/ClipKitty.sparkle.entitlements")
                }
                MacVariant::Hardened => repo.join("Sources/MacApp/ClipKitty.hardened.entitlements"),
                _ => unreachable!("non-DeveloperId variant routed here"),
            },
            embeds_provisioning_profile: matches!(variant, MacVariant::SparkleRelease),
        }),
        SigningMode::AppStore => Ok(SigningPlan::AppStore {
            identity: env::var("APPSTORE_SIGNING_IDENTITY")
                .unwrap_or_else(|_| "3rd Party Mac Developer Application".to_string()),
            entitlements: repo.join("Sources/MacApp/ClipKitty.appstore.entitlements"),
            provisioning_profile: env::var("PROVISIONING_PROFILE")
                .ok()
                .filter(|p| !p.is_empty())
                .map(Utf8PathBuf::from),
        }),
        SigningMode::Unsigned => unreachable!("Unsigned excluded above"),
    }
}

pub(crate) fn sign_app(
    repo: &RepoRoot,
    request: &SignAppRequest,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    let plan = signing_plan(repo, request.variant)?;

    if dry_run {
        match &plan {
            SigningPlan::DeveloperId {
                identity,
                entitlements,
                embeds_provisioning_profile,
            } => reporter.info(&format!(
                "[dry-run] would build + sign {:?} with identity `{identity}` using entitlements {entitlements}{}",
                request.variant,
                if *embeds_provisioning_profile {
                    " and embed the Developer ID provisioning profile"
                } else {
                    ""
                }
            )),
            SigningPlan::AppStore {
                identity,
                entitlements,
                provisioning_profile,
            } => {
                let profile = match provisioning_profile {
                    Some(p) => format!(" (embedding profile {p})"),
                    None => String::new(),
                };
                reporter.info(&format!(
                    "[dry-run] would build + sign {:?} with identity `{identity}` using entitlements {entitlements}{profile}",
                    request.variant
                ));
            }
        }
        return Ok(());
    }

    match &plan {
        SigningPlan::DeveloperId { identity, .. } | SigningPlan::AppStore { identity, .. } => {
            if !apple::codesign_available(reporter, identity)? {
                return Err(anyhow!(
                    "signing identity '{identity}' not available in keychain search list"
                ));
            }
        }
    }

    build::stage_app(
        repo,
        &build::BuildAppRequest {
            variant: request.variant,
            version: request.version.clone(),
            build_number: request.build_number.clone(),
        },
        false,
        reporter,
    )?;

    let app_path = build::staged_app_path(repo, request.variant);
    if !app_path.as_std_path().is_dir() {
        return Err(anyhow!("staged app not found at {app_path}"));
    }

    match &plan {
        SigningPlan::DeveloperId {
            identity,
            entitlements,
            embeds_provisioning_profile,
        } => {
            if *embeds_provisioning_profile {
                embed_developer_id_profile(repo, &app_path, reporter)?;
            }
            reporter.info(&format!(
                "Signing {APP_NAME} ({:?}) with '{identity}'...",
                request.variant
            ));
            apple::codesign(
                reporter,
                CodesignArgs {
                    identity,
                    entitlements,
                    include_timestamp: true,
                    bundle: &app_path,
                },
            )?;
        }
        SigningPlan::AppStore {
            identity,
            entitlements,
            provisioning_profile,
        } => {
            if let Some(src) = provisioning_profile {
                reporter.info("Embedding provisioning profile...");
                let dst = app_path.join("Contents/embedded.provisionprofile");
                fs::copy(src.as_std_path(), dst.as_std_path())
                    .map_err(|e| anyhow!("copying provisioning profile: {e}"))?;
            }
            reporter.info(&format!(
                "Signing {APP_NAME} ({:?}) with '{identity}'...",
                request.variant
            ));
            apple::codesign(
                reporter,
                CodesignArgs {
                    identity,
                    entitlements,
                    include_timestamp: false,
                    bundle: &app_path,
                },
            )?;
        }
    }
    apple::codesign_verify(reporter, &app_path)?;
    reporter.success(&format!("Signed app staged at {app_path}"));
    Ok(())
}

fn embed_developer_id_profile(
    repo: &RepoRoot,
    app_path: &Utf8PathBuf,
    reporter: &Reporter,
) -> Result<()> {
    let profile_bytes = if let Ok(path) = env::var("DEVELOPER_ID_PROVISIONING_PROFILE") {
        fs::read(&path)
            .map_err(|err| anyhow!("reading DEVELOPER_ID_PROVISIONING_PROFILE `{path}`: {err}"))?
    } else {
        decode_secret_base64(repo, "DEVELOPER_ID_PROVISION_PROFILE_BASE64", reporter)?
    };
    let destination = app_path.join("Contents/embedded.provisionprofile");
    fs::write(destination.as_std_path(), profile_bytes)
        .map_err(|err| anyhow!("writing embedded Developer ID provisioning profile: {err}"))?;
    Ok(())
}

const APP_NAME: &str = "ClipKitty";

pub(crate) fn setup(
    repo: &RepoRoot,
    request: &SetupRequest,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        let verb = match request.action {
            SetupAction::Init => "set up",
            SetupAction::Teardown => "tear down",
        };
        reporter.info(&format!(
            "[dry-run] would {verb} signing flow {:?}",
            request.flow,
        ));
        return Ok(());
    }

    match (request.flow, request.action) {
        (SetupFlow::AppStore, SetupAction::Init) => setup_appstore(repo, reporter),
        (SetupFlow::AppStore, SetupAction::Teardown) => {
            delete_temp_keychain(&appstore_keychain_path()?, reporter)
        }
        (SetupFlow::Dev, SetupAction::Init) => setup_dev(repo, reporter),
        (SetupFlow::Dev, SetupAction::Teardown) => {
            delete_temp_keychain(&dev_keychain_path()?, reporter)
        }
    }
}

fn setup_appstore(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let keychain_path = appstore_keychain_path()?;
    delete_temp_keychain(&keychain_path, reporter)?;
    if all_codesigning_identities_available(
        reporter,
        &[
            "3rd Party Mac Developer Application",
            "3rd Party Mac Developer Installer",
        ],
    )? {
        reporter.info("Signing certificates already available");
        return Ok(());
    }

    let keychain_password = random_password();
    let app_cert = temp_p12_secret(
        repo,
        "APPSTORE_APP_CERT_BASE64",
        "P12_PASSWORD",
        "appstore-app",
    )?;
    let installer_cert = temp_p12_secret(
        repo,
        "APPSTORE_CERT_BASE64",
        "P12_PASSWORD",
        "appstore-installer",
    )?;

    create_unlocked_temp_keychain(&keychain_path, &keychain_password, reporter)?;
    ensure_wwdr_certificate(reporter)?;
    import_certificate(&keychain_path, &app_cert, true, reporter)?;
    import_certificate(&keychain_path, &installer_cert, true, reporter)?;
    dedupe_certificates(
        &keychain_path,
        "3rd Party Mac Developer Application",
        reporter,
    )?;
    set_partition_list(
        &keychain_path,
        &keychain_password,
        "apple-tool:,apple:,codesign:,productbuild:",
        reporter,
    )?;
    prepend_keychain_to_search_list(&keychain_path, reporter)?;
    reporter.success("Signing keychain ready: clipkitty_signing.keychain-db");
    Ok(())
}

fn setup_dev(repo: &RepoRoot, reporter: &Reporter) -> Result<()> {
    let keychain_path = dev_keychain_path()?;
    delete_temp_keychain(&keychain_path, reporter)?;
    purge_stale_temp_keychains(reporter)?;

    if all_codesigning_identities_available(
        reporter,
        &["Developer ID Application", "Apple Development"],
    )? {
        reporter.info("Developer ID and Apple Development certificates already available");
        return Ok(());
    }

    let keychain_password = random_password();
    let dev_id = temp_p12_secret(
        repo,
        "MACOS_P12_BASE64",
        "MACOS_P12_PASSWORD",
        "developer-id",
    )?;
    let apple_dev = temp_p12_secret(
        repo,
        "MAC_DEV_P12_BASE64",
        "MAC_DEV_P12_PASSWORD",
        "apple-dev",
    )?;

    create_unlocked_temp_keychain(&keychain_path, &keychain_password, reporter)?;
    import_certificate(&keychain_path, &dev_id, true, reporter)?;
    import_certificate(&keychain_path, &apple_dev, true, reporter)?;
    set_partition_list(
        &keychain_path,
        &keychain_password,
        "apple-tool:,apple:,codesign:",
        reporter,
    )?;
    prepend_keychain_to_search_list(&keychain_path, reporter)?;
    reporter.success("Developer signing keychain ready: clipkitty_dev.keychain-db");
    Ok(())
}

fn appstore_keychain_path() -> Result<Utf8PathBuf> {
    let home = env::var("HOME").map_err(|err| anyhow!("HOME is not set: {err}"))?;
    Ok(Utf8PathBuf::from(home).join("Library/Keychains/clipkitty_signing.keychain-db"))
}

fn dev_keychain_path() -> Result<Utf8PathBuf> {
    let home = env::var("HOME").map_err(|err| anyhow!("HOME is not set: {err}"))?;
    Ok(Utf8PathBuf::from(home).join("Library/Keychains/clipkitty_dev.keychain-db"))
}

fn random_password() -> String {
    Uuid::new_v4().simple().to_string()
}

fn delete_temp_keychain(path: &Utf8PathBuf, reporter: &Reporter) -> Result<()> {
    let _ = Runner::new(reporter, "security")
        .arg("delete-keychain")
        .arg(path.as_std_path())
        .status()?;
    Ok(())
}

fn create_unlocked_temp_keychain(
    path: &Utf8PathBuf,
    password: &str,
    reporter: &Reporter,
) -> Result<()> {
    delete_temp_keychain(path, reporter)?;
    Runner::new(reporter, "security")
        .args(["create-keychain", "-p"])
        .arg(password)
        .arg(path.as_std_path())
        .run()?;
    Runner::new(reporter, "security")
        .arg("set-keychain-settings")
        .arg(path.as_std_path())
        .run()?;
    Runner::new(reporter, "security")
        .args(["unlock-keychain", "-p"])
        .arg(password)
        .arg(path.as_std_path())
        .run()
}

fn prepend_keychain_to_search_list(path: &Utf8PathBuf, reporter: &Reporter) -> Result<()> {
    let mut args = vec![
        "list-keychains".to_string(),
        "-d".to_string(),
        "user".to_string(),
        "-s".to_string(),
        path.as_str().to_string(),
    ];
    for existing in list_keychains(reporter)? {
        if existing != path.as_str() {
            args.push(existing);
        }
    }
    Runner::new(reporter, "security").args(args).run()
}

fn purge_stale_temp_keychains(reporter: &Reporter) -> Result<()> {
    let mut clean = Vec::new();
    for keychain in list_keychains(reporter)? {
        if keychain.contains("/login.keychain") || keychain.starts_with("/Library/") {
            clean.push(keychain);
            continue;
        }

        let status = Runner::new(reporter, "security")
            .arg("show-keychain-info")
            .arg(&keychain)
            .status()?;
        if status.success() {
            clean.push(keychain);
        } else {
            reporter.info(&format!(
                "Removing stale keychain from search list: {}",
                Utf8PathBuf::from(&keychain)
                    .file_name()
                    .unwrap_or(&keychain)
            ));
            let _ = Runner::new(reporter, "security")
                .arg("delete-keychain")
                .arg(&keychain)
                .status();
        }
    }

    let mut runner = Runner::new(reporter, "security").args(["list-keychains", "-d", "user", "-s"]);
    for keychain in clean {
        runner = runner.arg(keychain);
    }
    runner.run()
}

fn list_keychains(reporter: &Reporter) -> Result<Vec<String>> {
    let output = Runner::new(reporter, "security")
        .args(["list-keychains", "-d", "user"])
        .output()?;
    Ok(output
        .stdout_string()?
        .lines()
        .map(|line| line.trim().trim_matches('"').to_string())
        .filter(|line| !line.is_empty())
        .collect())
}

fn all_codesigning_identities_available(reporter: &Reporter, identities: &[&str]) -> Result<bool> {
    let output = Runner::new(reporter, "security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .output()?;
    let text = output.stdout_string()?;
    Ok(identities.iter().all(|identity| text.contains(identity)))
}

struct ImportedP12 {
    file: NamedTempFile,
    password: String,
}

fn temp_p12_secret(
    repo: &RepoRoot,
    base64_secret: &str,
    password_secret: &str,
    stem: &str,
) -> Result<ImportedP12> {
    let reporter = crate::output::Reporter::new(false);
    let cert_bytes = decode_secret_base64(repo, base64_secret, &reporter)?;
    let password = secret_text(repo, password_secret, &reporter)?;
    let file = NamedTempFile::new().map_err(|err| anyhow!("creating temp {stem} cert: {err}"))?;
    fs::write(file.path(), cert_bytes)
        .map_err(|err| anyhow!("writing temporary {stem} certificate: {err}"))?;
    Ok(ImportedP12 { file, password })
}

fn decode_secret_base64(repo: &RepoRoot, name: &str, reporter: &Reporter) -> Result<Vec<u8>> {
    let bytes = crate::cmd::secrets::read_secret(
        repo,
        &repo.join(format!("secrets/{name}.age")),
        reporter,
    )?;
    let text =
        String::from_utf8(bytes).map_err(|err| anyhow!("{name} secret is not UTF-8: {err}"))?;
    // Some secrets are line-wrapped base64 (standard `base64` CLI output wraps
    // at column 76). The standard engine rejects internal whitespace, so strip
    // it all before decoding.
    let cleaned: String = text.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD
        .decode(&cleaned)
        .map_err(|err| anyhow!("decoding {name}: {err}"))
}

fn secret_text(repo: &RepoRoot, name: &str, reporter: &Reporter) -> Result<String> {
    let bytes = crate::cmd::secrets::read_secret(
        repo,
        &repo.join(format!("secrets/{name}.age")),
        reporter,
    )?;
    String::from_utf8(bytes)
        .map(|text| text.trim().to_string())
        .map_err(|err| anyhow!("{name} secret is not UTF-8: {err}"))
}

fn import_certificate(
    keychain_path: &Utf8PathBuf,
    imported: &ImportedP12,
    allow_productbuild: bool,
    reporter: &Reporter,
) -> Result<()> {
    let mut runner = Runner::new(reporter, "security")
        .arg("import")
        .arg(imported.file.path())
        .arg("-k")
        .arg(keychain_path.as_std_path())
        .arg("-P")
        .arg(&imported.password)
        .args(["-T", "/usr/bin/codesign"]);
    if allow_productbuild {
        runner = runner.arg("-T").arg("/usr/bin/productbuild");
    }
    runner.run()
}

fn ensure_wwdr_certificate(reporter: &Reporter) -> Result<()> {
    let status = Runner::new(reporter, "security")
        .args([
            "find-certificate",
            "-c",
            "Apple Worldwide Developer Relations Certification Authority",
            "/Library/Keychains/System.keychain",
        ])
        .status()?;
    if status.success() {
        return Ok(());
    }

    let cert = NamedTempFile::new().map_err(|err| anyhow!("creating temp WWDR cert: {err}"))?;
    Runner::new(reporter, "curl")
        .arg("-sLo")
        .arg(cert.path())
        .arg("https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer")
        .run()?;
    Runner::new(reporter, "shasum")
        .args(["-a", "256", "--check"])
        .stdin_bytes(format!(
            "dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f  {}\n",
            cert.path().display()
        ))
        .run()?;
    Runner::new(reporter, "sudo")
        .args([
            "security",
            "add-trusted-cert",
            "-d",
            "-r",
            "unspecified",
            "-k",
            "/Library/Keychains/System.keychain",
        ])
        .arg(cert.path())
        .run()
}

fn dedupe_certificates(
    keychain_path: &Utf8PathBuf,
    common_name: &str,
    reporter: &Reporter,
) -> Result<()> {
    let output = Runner::new(reporter, "security")
        .args(["find-certificate", "-a", "-c"])
        .arg(common_name)
        .arg("-Z")
        .arg(keychain_path.as_std_path())
        .output()?;
    let hashes = output
        .stdout_string()?
        .lines()
        .filter_map(|line| line.trim().strip_prefix("SHA-1 hash: "))
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    for hash in hashes.into_iter().skip(1) {
        let _ = Runner::new(reporter, "security")
            .args(["delete-certificate", "-Z"])
            .arg(hash)
            .arg(keychain_path.as_std_path())
            .status();
    }
    Ok(())
}

fn set_partition_list(
    keychain_path: &Utf8PathBuf,
    keychain_password: &str,
    services: &str,
    reporter: &Reporter,
) -> Result<()> {
    Runner::new(reporter, "security")
        .args(["set-key-partition-list", "-S"])
        .arg(services)
        .args(["-s", "-k"])
        .arg(keychain_password)
        .arg(keychain_path.as_std_path())
        .run()
}
