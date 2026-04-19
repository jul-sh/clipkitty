//! `clipkitty release` — build + sign + publish orchestration.
//!
//! Apple tooling still lives at the edge (`xcrun`, `asc`, `productbuild`,
//! `hdiutil`, `swift`), but release policy, path derivation, and sequencing
//! are Rust-owned here.

use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::fs;

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tempfile::{tempdir, NamedTempFile};

use crate::cli::{
    AppcastCmd, AppcastGenerateArgs, AppcastUpdateStateArgs, DmgArgs, ReleaseCmd, ReleaseMacArgs,
};
use crate::cmd::build;
use crate::cmd::secrets;
use crate::cmd::sign;
use crate::model::{AscAuthField, MacVariant, SetupAction, SideEffectLevel};
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

pub fn run(cmd: &ReleaseCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::Credentialed;
    let repo = RepoRoot::discover(reporter)?;
    match cmd {
        ReleaseCmd::MacosAppstore(args) => macos_appstore(&repo, args, dry_run, reporter),
        ReleaseCmd::IosAppstore(args) => ios_appstore(&repo, args, dry_run, reporter),
        ReleaseCmd::Dmg(args) => dmg(&repo, args, dry_run, reporter),
        ReleaseCmd::Appcast(sub) => appcast(&repo, sub, dry_run, reporter),
    }
}

fn macos_appstore(
    repo: &RepoRoot,
    args: &ReleaseMacArgs,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would build + sign + upload macOS AppStore {} ({})",
            args.version, args.build_number
        ));
        return Ok(());
    }

    let mut signing_session = AppStoreSigningSession::begin(repo, reporter)?;
    signing_session.ensure_provisioning_profile()?;

    sign::sign_app(
        repo,
        &sign::SignAppRequest {
            variant: MacVariant::AppStore,
            version: Some(args.version.clone()),
            build_number: Some(args.build_number.clone()),
        },
        false,
        reporter,
    )?;

    let app_path = build::staged_app_path(repo, MacVariant::AppStore);
    if !app_path.as_std_path().is_dir() {
        return Err(anyhow!("staged AppStore app not found at {app_path}"));
    }
    let installer_identity = std::env::var("INSTALLER_IDENTITY")
        .unwrap_or_else(|_| "3rd Party Mac Developer Installer".to_string());
    let pkg = repo.join("ClipKitty.pkg");
    if pkg.as_std_path().exists() {
        fs::remove_file(pkg.as_std_path())
            .with_context(|| format!("removing existing installer package at {pkg}"))?;
    }
    reporter.info(&format!("Building installer package → {pkg}"));
    Runner::new(reporter, "productbuild")
        .arg("--component")
        .arg(app_path.as_std_path())
        .args(["/Applications", "--sign"])
        .arg(&installer_identity)
        .arg(pkg.as_std_path())
        .run()?;

    publish(repo, "macos", &args.version, reporter)
}

struct AppStoreSigningSession<'a> {
    repo: &'a RepoRoot,
    reporter: &'a Reporter,
    previous_provisioning_profile: Option<OsString>,
    hydrated_provisioning_profile: Option<Utf8PathBuf>,
}

impl<'a> AppStoreSigningSession<'a> {
    fn begin(repo: &'a RepoRoot, reporter: &'a Reporter) -> Result<Self> {
        sign::setup(
            repo,
            &sign::SetupRequest {
                flow: sign::SetupFlow::AppStore,
                action: SetupAction::Init,
            },
            false,
            reporter,
        )?;
        Ok(Self {
            repo,
            reporter,
            previous_provisioning_profile: env::var_os("PROVISIONING_PROFILE"),
            hydrated_provisioning_profile: None,
        })
    }

    fn ensure_provisioning_profile(&mut self) -> Result<()> {
        let has_external_profile = self
            .previous_provisioning_profile
            .as_ref()
            .is_some_and(|value| !value.is_empty());
        if has_external_profile {
            return Ok(());
        }

        let secret_path = self.repo.join("secrets/PROVISION_PROFILE_BASE64.age");
        if !secret_path.as_std_path().is_file() {
            return Err(anyhow!(
                "PROVISIONING_PROFILE is unset and provisioning secret not found at {secret_path}"
            ));
        }

        self.reporter
            .info("Decrypting provisioning profile from secrets...");
        let encoded = secrets::read_secret(self.repo, &secret_path, self.reporter)
            .with_context(|| format!("decrypting {secret_path}"))?;
        let encoded = std::str::from_utf8(&encoded)
            .context("PROVISION_PROFILE_BASE64 secret is not valid UTF-8")?;
        let cleaned: String = encoded.chars().filter(|c| !c.is_whitespace()).collect();
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&cleaned)
            .context("decoding PROVISION_PROFILE_BASE64")?;

        let profile_path = self.repo.join("ClipKitty.provisionprofile");
        fs::write(profile_path.as_std_path(), decoded)
            .with_context(|| format!("writing provisioning profile to {profile_path}"))?;
        env::set_var("PROVISIONING_PROFILE", profile_path.as_std_path());
        self.hydrated_provisioning_profile = Some(profile_path);
        Ok(())
    }
}

impl Drop for AppStoreSigningSession<'_> {
    fn drop(&mut self) {
        match &self.previous_provisioning_profile {
            Some(value) => env::set_var("PROVISIONING_PROFILE", value),
            None => env::remove_var("PROVISIONING_PROFILE"),
        }

        if let Some(path) = &self.hydrated_provisioning_profile {
            let _ = fs::remove_file(path.as_std_path());
        }

        let _ = sign::setup(
            self.repo,
            &sign::SetupRequest {
                flow: sign::SetupFlow::AppStore,
                action: SetupAction::Teardown,
            },
            false,
            self.reporter,
        );
    }
}

fn ios_appstore(
    repo: &RepoRoot,
    args: &ReleaseMacArgs,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would archive + export + upload iOS AppStore {} ({})",
            args.version, args.build_number
        ));
        return Ok(());
    }

    build::generate(repo, false, reporter)?;
    build::archive_ios(
        repo,
        &build::ArchiveIosRequest {
            version: args.version.clone(),
            build_number: args.build_number.clone(),
            archive_path: None,
        },
        false,
        reporter,
    )?;

    publish(repo, "ios", &args.version, reporter)
}

fn publish(repo: &RepoRoot, platform: &str, version: &str, reporter: &Reporter) -> Result<()> {
    let platform = publish_platform(platform)?;
    if !tool_exists(reporter, "asc")? {
        return Err(anyhow!(
            "asc CLI not found. Enter the Nix dev shell (nix develop) or install .#asc"
        ));
    }

    let artifact = repo.join(platform.pkg_name);
    if !artifact.as_std_path().is_file() {
        return Err(anyhow!(
            "{artifact} not found. Build the {} release artifact first.",
            platform.label
        ));
    }

    reporter.info("Decrypting App Store Connect secrets...");
    let asc_key_id = secrets::resolve_asc_field(repo, AscAuthField::KeyId, reporter)?;
    let asc_issuer_id = secrets::resolve_asc_field(repo, AscAuthField::IssuerId, reporter)?;
    let asc_private_key_b64 =
        secrets::resolve_asc_field(repo, AscAuthField::PrivateKeyB64, reporter)?;

    let key_bytes = base64::engine::general_purpose::STANDARD
        .decode(asc_private_key_b64.trim())
        .context("decoding ASC private key")?;
    let asc_key_file = NamedTempFile::new().context("creating temporary ASC key file")?;
    fs::set_permissions(
        asc_key_file.path(),
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )
    .ok();
    fs::write(asc_key_file.path(), &key_bytes).context("writing ASC private key")?;

    let altool_key_dir =
        Utf8PathBuf::from(env::var("HOME").context("HOME is not set")?).join(".private_keys");
    fs::create_dir_all(altool_key_dir.as_std_path())
        .with_context(|| format!("creating {altool_key_dir}"))?;
    let altool_key_path = altool_key_dir.join(format!("AuthKey_{asc_key_id}.p8"));
    let altool_key_existed = altool_key_path.as_std_path().is_file();
    if !altool_key_existed {
        fs::write(altool_key_path.as_std_path(), &key_bytes)
            .with_context(|| format!("writing {altool_key_path}"))?;
        fs::set_permissions(
            altool_key_path.as_std_path(),
            std::os::unix::fs::PermissionsExt::from_mode(0o600),
        )
        .ok();
    }

    let asc_env = [
        ("ASC_KEY_ID", asc_key_id.as_str()),
        ("ASC_ISSUER_ID", asc_issuer_id.as_str()),
        (
            "ASC_PRIVATE_KEY_PATH",
            asc_key_file
                .path()
                .to_str()
                .ok_or_else(|| anyhow!("temporary ASC key path is not UTF-8"))?,
        ),
    ];

    reporter.info(&format!("Authenticated (key: {asc_key_id})"));

    let publish_result = (|| -> Result<()> {
        reporter.info("\n=== Uploading binary ===");
        upload_binary(repo, platform, &asc_key_id, &asc_issuer_id, reporter)?;
        reporter.info("\n=== Uploading metadata ===");
        let version_id = ensure_editable_version(repo, platform, version, &asc_env, reporter)?;
        let Some(version_id) = version_id else {
            return Ok(());
        };
        import_metadata(repo, platform, &version_id, &asc_env, reporter)?;
        reporter.info("\n=== Uploading screenshots ===");
        upload_screenshots(repo, platform, &version_id, &asc_env, reporter)?;
        reporter.info("\n=== Publish complete ===");
        Ok(())
    })();

    if !altool_key_existed {
        let _ = fs::remove_file(altool_key_path.as_std_path());
    }
    publish_result
}

#[derive(Debug, Clone, Copy)]
struct PublishPlatform {
    label: &'static str,
    app_id: &'static str,
    altool_type: &'static str,
    asc_platform: &'static str,
    pkg_name: &'static str,
    metadata_dir_name: &'static str,
    marketing_dir_name: &'static str,
    screenshot_device_types: &'static [&'static str],
}

const MACOS_PLATFORM: PublishPlatform = PublishPlatform {
    label: "macOS",
    app_id: "6759137247",
    altool_type: "osx",
    asc_platform: "MAC_OS",
    pkg_name: "ClipKitty.pkg",
    metadata_dir_name: "metadata",
    marketing_dir_name: "marketing",
    screenshot_device_types: &["APP_DESKTOP"],
};

const IOS_PLATFORM: PublishPlatform = PublishPlatform {
    label: "iOS",
    app_id: "6759137247",
    altool_type: "ios",
    asc_platform: "IOS",
    pkg_name: "ClipKittyiOS.ipa",
    metadata_dir_name: "metadata",
    marketing_dir_name: "marketing-ios",
    screenshot_device_types: &["IPHONE_61"],
};

const LOCALE_MAP: &[(&str, &str)] = &[
    ("en", "en-US"),
    ("es", "es-ES"),
    ("de", "de-DE"),
    ("fr", "fr-FR"),
    ("ja", "ja"),
    ("ko", "ko"),
    ("pt-BR", "pt-BR"),
    ("ru", "ru"),
    ("zh-Hans", "zh-Hans"),
    ("zh-Hant", "zh-Hant"),
];

fn publish_platform(name: &str) -> Result<PublishPlatform> {
    match name {
        "macos" => Ok(MACOS_PLATFORM),
        "ios" => Ok(IOS_PLATFORM),
        _ => Err(anyhow!("unknown publish platform `{name}`")),
    }
}

fn upload_binary(
    repo: &RepoRoot,
    platform: PublishPlatform,
    asc_key_id: &str,
    asc_issuer_id: &str,
    reporter: &Reporter,
) -> Result<()> {
    let artifact = repo.join(platform.pkg_name);
    let output = Runner::new(reporter, "xcrun")
        .args(["altool", "--upload-package"])
        .arg(artifact.as_std_path())
        .arg("--type")
        .arg(platform.altool_type)
        .arg("--apiKey")
        .arg(asc_key_id)
        .arg("--apiIssuer")
        .arg(asc_issuer_id)
        .capture_stdout()
        .capture_stderr()
        .output_status()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}{stderr}");
    let succeeded = combined.contains("UPLOAD SUCCEEDED");
    let failed = !output.status.success()
        || combined.contains("Failed to upload package.")
        || combined.contains(" ERROR: ");
    if failed || !succeeded {
        return Err(anyhow!(
            "binary upload failed (altool exit {}): {}",
            output.status,
            combined.trim()
        ));
    }
    reporter.info("Binary uploaded.");
    Ok(())
}

fn ensure_editable_version(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<Option<String>> {
    let versions = asc_json(
        repo,
        &[
            "versions",
            "list",
            "--app",
            platform.app_id,
            "--platform",
            platform.asc_platform,
            "--state",
            "PREPARE_FOR_SUBMISSION",
        ],
        asc_env,
        reporter,
    )?;

    let mut version_id = None;

    if let Some(existing) = versions.first() {
        let existing_version = existing
            .get("attributes")
            .and_then(|attrs| attrs.get("versionString"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let existing_id = existing
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("version list entry missing id"))?;

        if existing_version == version {
            version_id = Some(existing_id.to_string());
        } else {
            reporter.info(&format!(
                "Deleting stale PREPARE_FOR_SUBMISSION version {existing_version} (ID: {existing_id})..."
            ));
            let result = asc_command(
                repo,
                &["versions", "delete", "--version-id", existing_id, "--confirm"],
                asc_env,
                reporter,
            );
            if let Err(err) = result {
                reporter.info(&format!("Warning: Could not delete stale version: {err}"));
            }
        }
    }

    if version_id.is_none() {
        reporter.info(&format!("Creating new App Store version {version}..."));
        let output = asc_command(
            repo,
            &[
                "versions",
                "create",
                "--app",
                platform.app_id,
                "--platform",
                platform.asc_platform,
                "--version",
                version,
                "--release-type",
                "MANUAL",
            ],
            asc_env,
            reporter,
        );
        match output {
            Ok(output) => {
                let created = parse_asc_data(&output.stdout)?;
                if let Some(id) = created.get("id").and_then(Value::as_str) {
                    reporter.info(&format!("Created version {version} (ID: {id})"));
                    version_id = Some(id.to_string());
                }
            }
            Err(err) => {
                reporter.info(&format!("Warning: Could not create version {version}: {err}"));
                reporter.info(
                    "Skipping metadata and screenshot upload (binary was uploaded successfully).",
                );
                return Ok(None);
            }
        }
    }

    if let Some(id) = &version_id {
        reporter.info(&format!("Target version ID: {id}"));
        Ok(Some(id.clone()))
    } else {
        reporter.info("Warning: no editable App Store version available; skipping metadata and screenshot upload.");
        Ok(None)
    }
}

fn import_metadata(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version_id: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let metadata_dir = repo.join(format!("distribution/{}", platform.metadata_dir_name));
    let import_dir = tempdir().context("creating temporary metadata import dir")?;
    let import_root = Utf8PathBuf::from_path_buf(import_dir.path().to_path_buf())
        .map_err(|p| anyhow!("non-UTF-8 tempdir path: {p:?}"))?;
    let import_metadata = import_root.join("metadata");
    let screenshots_dir = import_root.join("screenshots");
    copy_dir_recursive(&metadata_dir, &import_metadata)?;
    fs::create_dir_all(screenshots_dir.as_std_path())?;

    let args = vec![
        "migrate",
        "import",
        "--app",
        platform.app_id,
        "--version-id",
        version_id,
        "--fastlane-dir",
        import_root.as_str(),
    ];
    let output = asc_command(repo, &args, asc_env, reporter);
    match output {
        Ok(_) => {
            reporter.info("Metadata uploaded.");
            Ok(())
        }
        Err(err) => {
            let release_notes_removed = remove_release_notes(&import_metadata)?;
            if release_notes_removed
                && err.to_string().contains("whatsNew")
                && err.to_string().contains("cannot be edited")
            {
                reporter.info(
                    "whatsNew rejected (first submission), retrying without release notes...",
                );
                asc_command(repo, &args, asc_env, reporter)?;
                reporter.info("Metadata uploaded.");
                Ok(())
            } else {
                Err(err)
            }
        }
    }
}

fn upload_screenshots(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version_id: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let localizations = asc_json(
        repo,
        &[
            "localizations",
            "list",
            "--version",
            version_id,
            "--paginate",
        ],
        asc_env,
        reporter,
    )?;
    let mut locale_to_id = BTreeMap::new();
    for localization in localizations {
        if let (Some(id), Some(locale)) = (
            localization.get("id").and_then(Value::as_str),
            localization
                .get("attributes")
                .and_then(|attrs| attrs.get("locale"))
                .and_then(Value::as_str),
        ) {
            locale_to_id.insert(locale.to_string(), id.to_string());
        }
    }

    let marketing_dir = repo.join(platform.marketing_dir_name);
    if !marketing_dir.as_std_path().is_dir() {
        reporter.info(&format!(
            "Warning: marketing directory not found: {marketing_dir}; skipping screenshot upload."
        ));
        return Ok(());
    }

    let mut uploaded_count = 0usize;
    let mut locale_dirs = fs::read_dir(marketing_dir.as_std_path())
        .with_context(|| format!("reading {marketing_dir}"))?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| Utf8PathBuf::from_path_buf(entry.path()).ok())
        .filter(|path| path.as_std_path().is_dir())
        .collect::<Vec<_>>();
    locale_dirs.sort();

    for locale_dir in locale_dirs {
        let Some(entry_name) = locale_dir.file_name() else {
            continue;
        };
        let Some(asc_locale) = locale_code(entry_name) else {
            continue;
        };
        let Some(localization_id) = locale_to_id.get(asc_locale) else {
            reporter.info(&format!(
                "Warning: no localization for {asc_locale}, skipping screenshots"
            ));
            continue;
        };

        let mut pngs = fs::read_dir(locale_dir.as_std_path())
            .with_context(|| format!("reading {locale_dir}"))?
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| Utf8PathBuf::from_path_buf(entry.path()).ok())
            .filter(|path| {
                path.extension() == Some("png")
                    && path
                        .file_name()
                        .is_some_and(|name| name.starts_with("screenshot_"))
            })
            .collect::<Vec<_>>();
        pngs.sort();
        if pngs.is_empty() {
            reporter.info(&format!("Warning: no screenshots found in {locale_dir}"));
            continue;
        }

        for device_type in platform.screenshot_device_types {
            reporter.info(&format!(
                "Deleting existing {device_type} screenshots for {asc_locale}..."
            ));
            let existing = asc_json(
                repo,
                &[
                    "screenshots",
                    "list",
                    "--version-localization",
                    localization_id,
                    "--paginate",
                ],
                asc_env,
                reporter,
            )
            .unwrap_or_default();
            for screenshot in &existing {
                if let Some(screenshot_id) = screenshot.get("id").and_then(Value::as_str) {
                    let _ = asc_command(
                        repo,
                        &["screenshots", "delete", "--id", screenshot_id, "--confirm"],
                        asc_env,
                        reporter,
                    );
                }
            }

            reporter.info(&format!(
                "Uploading {} {device_type} screenshots for {asc_locale}...",
                pngs.len()
            ));
            for png in &pngs {
                asc_command(
                    repo,
                    &[
                        "screenshots",
                        "upload",
                        "--version-localization",
                        localization_id,
                        "--device-type",
                        device_type,
                        "--path",
                        png.as_str(),
                    ],
                    asc_env,
                    reporter,
                )?;
            }
            uploaded_count += pngs.len();
        }
    }

    reporter.info(&format!("Total screenshots uploaded: {uploaded_count}"));
    Ok(())
}

fn remove_release_notes(dir: &Utf8Path) -> Result<bool> {
    let mut removed = false;
    if !dir.as_std_path().is_dir() {
        return Ok(false);
    }
    for entry in fs::read_dir(dir.as_std_path()).with_context(|| format!("reading {dir}"))? {
        let entry = entry?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
        if path.as_std_path().is_dir() {
            removed |= remove_release_notes(&path)?;
        } else if path.file_name() == Some("release_notes.txt") {
            fs::remove_file(path.as_std_path()).with_context(|| format!("removing {path}"))?;
            removed = true;
        }
    }
    Ok(removed)
}

fn locale_code(entry: &str) -> Option<&'static str> {
    LOCALE_MAP
        .iter()
        .find_map(|(source, target)| (*source == entry).then_some(*target))
}

fn asc_json(
    repo: &RepoRoot,
    args: &[&str],
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<Vec<Value>> {
    let output = asc_command(repo, args, asc_env, reporter)?;
    let parsed: Value =
        serde_json::from_slice(&output.stdout).context("parsing asc JSON response")?;
    let data = parse_asc_data_from_value(parsed)?;
    Ok(match data {
        Value::Array(items) => items,
        value => vec![value],
    })
}

fn asc_command(
    repo: &RepoRoot,
    args: &[&str],
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<crate::process::CommandOutput> {
    let mut runner = Runner::new(reporter, "asc").cwd(repo.as_path());
    for arg in args {
        runner = runner.arg(*arg);
    }
    for (key, value) in asc_env {
        runner = runner.env(*key, *value);
    }
    let output = runner.capture_stdout().capture_stderr().output_status()?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!(
            "`asc {}` failed: {}",
            args.join(" "),
            stderr.trim()
        ));
    }
    Ok(output)
}

fn parse_asc_data(bytes: &[u8]) -> Result<Value> {
    let parsed: Value = serde_json::from_slice(bytes).context("parsing asc response JSON")?;
    parse_asc_data_from_value(parsed)
}

fn parse_asc_data_from_value(value: Value) -> Result<Value> {
    if let Some(data) = value.get("data") {
        Ok(data.clone())
    } else {
        Ok(value)
    }
}

fn tool_exists(reporter: &Reporter, name: &str) -> Result<bool> {
    let output = Runner::new(reporter, "which")
        .arg(name)
        .capture_stdout()
        .capture_stderr()
        .output_status()?;
    Ok(output.status.success())
}

fn copy_dir_recursive(src: &Utf8Path, dst: &Utf8Path) -> Result<()> {
    if !src.as_std_path().is_dir() {
        return Err(anyhow!("source directory not found: {src}"));
    }
    fs::create_dir_all(dst.as_std_path()).with_context(|| format!("creating {dst}"))?;
    for entry in fs::read_dir(src.as_std_path()).with_context(|| format!("reading {src}"))? {
        let entry = entry?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
        let target = dst.join(path.file_name().unwrap());
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            // Preserve symlinks verbatim. Framework bundles depend on their
            // Versions/Current and top-level aliases (Resources, Headers, the
            // binary) being symlinks; following them here would both break the
            // bundle layout and trip fs::copy on symlink-to-directory targets.
            let link_target = fs::read_link(path.as_std_path())
                .with_context(|| format!("reading symlink {path}"))?;
            std::os::unix::fs::symlink(&link_target, target.as_std_path())
                .with_context(|| format!("recreating symlink {target}"))?;
        } else if file_type.is_dir() {
            copy_dir_recursive(&path, &target)?;
        } else {
            fs::copy(path.as_std_path(), target.as_std_path())
                .with_context(|| format!("copying {path} to {target}"))?;
        }
    }
    Ok(())
}

fn remove_if_exists(path: &Utf8Path) -> Result<()> {
    if !path.as_std_path().exists() {
        return Ok(());
    }
    if path.as_std_path().is_dir() {
        fs::remove_dir_all(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    } else {
        fs::remove_file(path.as_std_path()).with_context(|| format!("removing {path}"))?;
    }
    Ok(())
}

fn dir_size_megabytes(path: &Utf8Path) -> Result<u64> {
    fn visit(path: &Utf8Path) -> Result<u64> {
        let metadata =
            fs::symlink_metadata(path.as_std_path()).with_context(|| format!("stat {path}"))?;
        if metadata.is_file() {
            return Ok(metadata.len());
        }
        if metadata.file_type().is_symlink() {
            return Ok(0);
        }

        let mut total = 0_u64;
        for entry in fs::read_dir(path.as_std_path()).with_context(|| format!("reading {path}"))? {
            let entry = entry?;
            let child = Utf8PathBuf::from_path_buf(entry.path())
                .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
            total += visit(&child)?;
        }
        Ok(total)
    }

    let bytes = visit(path)?;
    Ok(bytes.div_ceil(1_048_576))
}

fn dmg(repo: &RepoRoot, args: &DmgArgs, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = args;
    let output = repo.join("ClipKitty.dmg");

    if dry_run {
        reporter.info(&format!(
            "[dry-run] would build and sign Sparkle app, then package DMG {output}"
        ));
        return Ok(());
    }

    sign::sign_app(
        repo,
        &sign::SignAppRequest {
            variant: MacVariant::SparkleRelease,
            version: None,
            build_number: None,
        },
        false,
        reporter,
    )?;

    let app = build::staged_app_path(repo, MacVariant::SparkleRelease);
    if !app.as_std_path().is_dir() {
        return Err(anyhow!("app not found at {app}"));
    }

    build_dmg(repo, &app, &output, reporter)
}

fn build_dmg(
    repo: &RepoRoot,
    app: &Utf8Path,
    output: &Utf8Path,
    reporter: &Reporter,
) -> Result<()> {
    let temp = tempdir().context("creating temporary DMG staging dir")?;
    let temp_root = Utf8PathBuf::from_path_buf(temp.path().to_path_buf())
        .map_err(|p| anyhow!("non-UTF-8 temp path: {p:?}"))?;
    let background_path = temp_root.join("background.png");
    let staging_dir = temp_root.join("staging");
    let background_dir = staging_dir.join(".background");
    let background_script = repo.join("distribution/create-dmg-background.swift");

    reporter.info("Generating DMG background image...");
    Runner::new(reporter, "swift")
        .arg(background_script.as_std_path())
        .arg(background_path.as_std_path())
        .cwd(repo.as_path())
        .run()?;

    copy_dir_recursive(app, &staging_dir.join(app.file_name().unwrap()))?;
    fs::create_dir_all(background_dir.as_std_path())
        .with_context(|| format!("creating {background_dir}"))?;
    fs::copy(
        background_path.as_std_path(),
        background_dir.join("background.png").as_std_path(),
    )
    .with_context(|| format!("copying background into {background_dir}"))?;
    remove_if_exists(output)?;

    if tool_exists(reporter, "create-dmg")? {
        reporter.info("Building DMG with create-dmg...");
        Runner::new(reporter, "create-dmg")
            .args(["--volname", "ClipKitty", "--background"])
            .arg(background_path.as_std_path())
            .args([
                "--window-pos",
                "200",
                "120",
                "--window-size",
                "660",
                "500",
                "--icon-size",
                "100",
                "--icon",
            ])
            .arg(app.file_name().unwrap())
            .args(["165", "280", "--hide-extension"])
            .arg(app.file_name().unwrap())
            .args(["--app-drop-link", "495", "280"])
            .arg(output.as_std_path())
            .arg(staging_dir.as_std_path())
            .run()?;
    } else {
        reporter.info("Building DMG with hdiutil (install create-dmg for prettier results)...");
        std::os::unix::fs::symlink(
            "/Applications",
            staging_dir.join("Applications").as_std_path(),
        )
        .context("creating Applications symlink")?;

        let temp_dmg = temp_root.join("temp.dmg");
        let dmg_size_mb = dir_size_megabytes(&staging_dir)? + 20;
        Runner::new(reporter, "hdiutil")
            .args(["create", "-srcfolder"])
            .arg(staging_dir.as_std_path())
            .args([
                "-volname",
                "ClipKitty",
                "-fs",
                "HFS+",
                "-fsargs",
                "-c c=64,a=16,e=16",
                "-format",
                "UDRW",
                "-size",
            ])
            .arg(format!("{dmg_size_mb}m"))
            .arg(temp_dmg.as_std_path())
            .run()?;

        let mountpoint = "/Volumes/ClipKitty";
        Runner::new(reporter, "hdiutil")
            .args(["attach", "-readwrite", "-noverify", "-noautoopen"])
            .arg(temp_dmg.as_std_path())
            .arg("-mountpoint")
            .arg(mountpoint)
            .run()?;

        let finder_script = r#"
tell application "Finder"
    tell disk "ClipKitty"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 100
        set background picture of viewOptions to file ".background:background.png"
        set position of item "ClipKitty.app" of container window to {165, 280}
        set position of item "Applications" of container window to {495, 280}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
"#;
        let _ = Runner::new(reporter, "osascript")
            .arg("-")
            .stdin_bytes(finder_script)
            .status();
        let _ = Runner::new(reporter, "sync").status();
        std::thread::sleep(std::time::Duration::from_secs(1));
        let detach = Runner::new(reporter, "hdiutil")
            .arg("detach")
            .arg(mountpoint)
            .status()?;
        if !detach.success() {
            Runner::new(reporter, "hdiutil")
                .arg("detach")
                .arg(mountpoint)
                .arg("-force")
                .run()?;
        }

        Runner::new(reporter, "hdiutil")
            .arg("convert")
            .arg(temp_dmg.as_std_path())
            .args(["-format", "UDZO", "-imagekey", "zlib-level=9", "-o"])
            .arg(output.as_std_path())
            .run()?;
    }

    reporter.success(&format!("DMG created successfully: {output}"));
    Ok(())
}

fn appcast(repo: &RepoRoot, sub: &AppcastCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    match sub {
        AppcastCmd::Generate(args) => appcast_generate(repo, args, dry_run, reporter),
        AppcastCmd::UpdateState(args) => appcast_update_state(repo, args, dry_run, reporter),
    }
}

fn appcast_generate(
    _repo: &RepoRoot,
    args: &AppcastGenerateArgs,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would render {} → {}",
            args.state_path, args.output_path
        ));
        return Ok(());
    }

    let state = read_appcast_state(&args.state_path)?;
    let xml = render_appcast_xml(&state)?;
    fs::write(args.output_path.as_std_path(), xml)
        .with_context(|| format!("writing {}", args.output_path))?;
    reporter.success(&format!("Rendered appcast → {}", args.output_path));
    Ok(())
}

fn appcast_update_state(
    _repo: &RepoRoot,
    args: &AppcastUpdateStateArgs,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would update {} ({}) → v{} @ {} ({} bytes)",
            args.state_path,
            args.channel.as_str(),
            args.version,
            args.url,
            args.length
        ));
        return Ok(());
    }

    let mut state = read_appcast_state(&args.state_path)?;
    let entry = AppcastRelease {
        version: args.version.clone(),
        url: args.url.clone(),
        signature: args.signature.clone(),
        length: args.length,
        published_at: Utc::now().to_rfc3339(),
    };
    match args.channel {
        crate::model::ReleaseChannel::Stable => state.stable = Some(entry),
        crate::model::ReleaseChannel::Beta => state.beta = Some(entry),
    }
    let json = serde_json::to_string_pretty(&state)?;
    fs::write(args.state_path.as_std_path(), format!("{json}\n"))
        .with_context(|| format!("writing {}", args.state_path))?;
    reporter.success(&format!("Updated appcast state → {}", args.state_path));
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AppcastState {
    #[serde(default)]
    beta: Option<AppcastRelease>,
    #[serde(default)]
    stable: Option<AppcastRelease>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AppcastRelease {
    version: String,
    url: String,
    signature: String,
    length: u64,
    published_at: String,
}

fn read_appcast_state(path: &Utf8Path) -> Result<AppcastState> {
    if !path.as_std_path().exists() {
        return Ok(AppcastState::default());
    }
    let raw = fs::read_to_string(path.as_std_path()).with_context(|| format!("reading {path}"))?;
    serde_json::from_str(&raw).with_context(|| format!("parsing {path}"))
}

fn render_appcast_xml(state: &AppcastState) -> Result<String> {
    let mut xml = String::from(
        r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ClipKitty Updates</title>
    <link>https://jul-sh.github.io/clipkitty/appcast.xml</link>
    <language>en</language>
"#,
    );

    if let Some(release) = &state.beta {
        push_appcast_item(&mut xml, "beta", release)?;
    }
    if let Some(release) = &state.stable {
        push_appcast_item(&mut xml, "stable", release)?;
    }

    xml.push_str("  </channel>\n</rss>\n");
    Ok(xml)
}

fn push_appcast_item(xml: &mut String, channel: &str, release: &AppcastRelease) -> Result<()> {
    let pub_date = format_pub_date(Some(&release.published_at))?;
    let title = if channel == "beta" {
        format!("ClipKitty {} Beta", release.version)
    } else {
        format!("ClipKitty {}", release.version)
    };
    writeln!(xml, "    <item>").unwrap();
    writeln!(xml, "      <title>{}</title>", xml_escape(&title)).unwrap();
    writeln!(
        xml,
        "      <sparkle:version>{}</sparkle:version>",
        xml_escape(&release.version)
    )
    .unwrap();
    writeln!(
        xml,
        "      <sparkle:shortVersionString>{}</sparkle:shortVersionString>",
        xml_escape(&release.version)
    )
    .unwrap();
    writeln!(
        xml,
        "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
    )
    .unwrap();
    if channel == "beta" {
        writeln!(xml, "      <sparkle:channel>beta</sparkle:channel>").unwrap();
    }
    writeln!(xml, "      <pubDate>{}</pubDate>", xml_escape(&pub_date)).unwrap();
    writeln!(
        xml,
        "      <enclosure url=\"{}\" type=\"application/octet-stream\" sparkle:edSignature=\"{}\" length=\"{}\" />",
        xml_escape(&release.url),
        xml_escape(&release.signature),
        release.length
    )
    .unwrap();
    writeln!(xml, "    </item>").unwrap();
    Ok(())
}

fn format_pub_date(value: Option<&str>) -> Result<String> {
    if let Some(value) = value.filter(|value| !value.is_empty()) {
        let normalized = value.replace('Z', "+00:00");
        let dt = DateTime::parse_from_rfc3339(&normalized)
            .with_context(|| format!("parsing RFC3339 timestamp `{value}`"))?;
        Ok(dt
            .with_timezone(&Utc)
            .format("%a, %d %b %Y %H:%M:%S GMT")
            .to_string())
    } else {
        Ok(Utc::now().format("%a, %d %b %Y %H:%M:%S GMT").to_string())
    }
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
