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
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use camino::{Utf8Path, Utf8PathBuf};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tempfile::{tempdir, NamedTempFile};

use crate::cli::{
    AppcastCmd, AppcastGenerateArgs, AppcastUpdateStateArgs, DmgArgs, ReleaseCmd, ReleaseMacArgs,
    VersionArgs, VersionField,
};
use crate::cmd::build;
use crate::cmd::secrets;
use crate::cmd::sign;
use crate::model::{AscAuthField, MacVariant, SetupAction, SideEffectLevel};
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;
use crate::version;

const ASC_BUILD_PROCESSING_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const ASC_BUILD_PROCESSING_POLL_INTERVAL: Duration = Duration::from_secs(15);

pub fn run(cmd: &ReleaseCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::Credentialed;
    let repo = RepoRoot::discover(reporter)?;
    match cmd {
        ReleaseCmd::MacosAppstore(args) => macos_appstore(&repo, args, dry_run, reporter),
        ReleaseCmd::IosAppstore(args) => ios_appstore(&repo, args, dry_run, reporter),
        ReleaseCmd::Dmg(args) => dmg(&repo, args, dry_run, reporter),
        ReleaseCmd::Appcast(sub) => appcast(&repo, sub, dry_run, reporter),
        ReleaseCmd::Version(args) => print_version(&repo, args, reporter),
    }
}

fn print_version(repo: &RepoRoot, args: &VersionArgs, reporter: &Reporter) -> Result<()> {
    let resolved = version::resolve(repo, reporter)?;
    let value = match args.field {
        VersionField::Version => resolved.version,
        VersionField::BuildNumber => resolved.build_number,
    };
    println!("{value}");
    Ok(())
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

    publish(repo, "macos", &args.version, &[], reporter)
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

    publish(repo, "ios", &args.version, &[IPAD_PLATFORM], reporter)
}

fn publish(
    repo: &RepoRoot,
    platform: &str,
    version: &str,
    extra_screenshot_platforms: &[PublishPlatform],
    reporter: &Reporter,
) -> Result<()> {
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

    // Bail out early before any heavy work (binary upload) if a prior version
    // is locked in review. We'll surface this as a friendly skip below.
    match check_no_blocking_version(repo, platform, version, &asc_env, reporter) {
        Ok(()) => {}
        Err(err) => {
            if let Some(locked) = err.downcast_ref::<VersionLockedError>() {
                reporter.info(&format!("Skipping {} publish: {locked}", platform.label));
                if !altool_key_existed {
                    let _ = fs::remove_file(altool_key_path.as_std_path());
                }
                return Ok(());
            }
            return Err(err);
        }
    }

    // Reject the publish before doing any work if a metadata locale is
    // missing required per-locale text. ASC will otherwise refuse to "Add for
    // Review" with errors like "Czech - What's New in This Version - This
    // field is required" — long after we've uploaded the binary.
    validate_metadata_locales(repo, platform)?;

    let publish_result = (|| -> Result<()> {
        reporter.info("\n=== Uploading binary ===");
        upload_binary(
            repo,
            platform,
            &asc_key_id,
            &asc_issuer_id,
            &altool_key_path,
            reporter,
        )?;
        reporter.info("\n=== Uploading metadata ===");
        let version_id = ensure_editable_version(repo, platform, version, &asc_env, reporter)?;
        attach_latest_valid_build(repo, platform, version, &version_id, &asc_env, reporter)?;
        import_metadata(repo, platform, &version_id, &asc_env, reporter)?;
        reporter.info(&format!(
            "\n=== Uploading {} screenshots ===",
            platform.label
        ));
        upload_screenshots(repo, platform, &version_id, &asc_env, reporter)?;
        if !platform.preview_device_types.is_empty() {
            reporter.info(&format!(
                "\n=== Uploading {} app preview videos ===",
                platform.label
            ));
            upload_app_previews(repo, platform, &version_id, &asc_env, reporter)?;
        }
        for extra in extra_screenshot_platforms {
            reporter.info(&format!("\n=== Uploading {} screenshots ===", extra.label));
            upload_screenshots(repo, *extra, &version_id, &asc_env, reporter)?;
        }
        reporter.info("\n=== Publish complete ===");
        Ok(())
    })();

    if !altool_key_existed {
        let _ = fs::remove_file(altool_key_path.as_std_path());
    }
    publish_result
}

/// How a version leaves review. `AFTER_APPROVAL` releases automatically the
/// moment Apple approves it, with no manual "Release this version" step. The
/// alternatives are `MANUAL` (wait for a human) and `SCHEDULED` (release on a
/// chosen date).
const RELEASE_TYPE: &str = "AFTER_APPROVAL";

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
    preview_device_types: &'static [&'static str],
}

impl PublishPlatform {
    /// Whether the upload artifact is an `.ipa` (iOS) rather than a `.pkg`
    /// (macOS). Drives the altool upload mode (`--upload-app` vs
    /// `--upload-package`).
    fn uses_ipa(&self) -> bool {
        self.pkg_name.ends_with(".ipa")
    }
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
    preview_device_types: &["DESKTOP"],
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
    preview_device_types: &[],
};

/// Shares `IOS_PLATFORM`'s app_id, IPA, and ASC version row. Only the
/// screenshot tree and device-type enum differ, so this is never used
/// for binary or metadata upload; it's passed as an extra screenshot
/// platform to `publish`.
const IPAD_PLATFORM: PublishPlatform = PublishPlatform {
    label: "iPad",
    app_id: "6759137247",
    altool_type: "ios",
    asc_platform: "IOS",
    pkg_name: "ClipKittyiOS.ipa",
    metadata_dir_name: "metadata",
    marketing_dir_name: "marketing-ipad",
    screenshot_device_types: &["IPAD_PRO_3GEN_129"],
    preview_device_types: &[],
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

const EXPECTED_SCREENSHOT_FILES: &[&str] =
    &["screenshot_1.png", "screenshot_2.png", "screenshot_3.png"];

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
    asc_private_key_path: &Utf8Path,
    reporter: &Reporter,
) -> Result<()> {
    if platform.uses_ipa() {
        upload_ios_archive_with_xcodebuild(
            repo,
            asc_key_id,
            asc_issuer_id,
            asc_private_key_path,
            reporter,
        )?;
        reporter.info("Binary uploaded.");
        return Ok(());
    }

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
        // `--verbose` makes altool log exactly which file inside the bundle it
        // inspects for the executable, so a 90207 surfaces a concrete reason
        // instead of the opaque "does not contain a bundle executable".
        .arg("--verbose")
        .capture_stdout()
        .capture_stderr()
        .output_status()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}{stderr}");
    // altool prints "UPLOAD SUCCEEDED" for --upload-package and
    // "No errors uploading" for --upload-app; accept either.
    let succeeded =
        combined.contains("UPLOAD SUCCEEDED") || combined.contains("No errors uploading");
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

fn upload_ios_archive_with_xcodebuild(
    repo: &RepoRoot,
    asc_key_id: &str,
    asc_issuer_id: &str,
    asc_private_key_path: &Utf8Path,
    reporter: &Reporter,
) -> Result<()> {
    let archive_path = repo.join("DerivedData/ClipKittyiOS.xcarchive");
    if !archive_path.as_std_path().is_dir() {
        return Err(anyhow!(
            "iOS archive {archive_path} not found. Build the iOS release archive first."
        ));
    }

    let source_export_plist = repo.join("distribution/ExportOptions-iOS.plist");
    if !source_export_plist.as_std_path().is_file() {
        return Err(anyhow!(
            "iOS export options plist not found at {source_export_plist}"
        ));
    }

    let upload_dir = tempdir().context("creating temporary iOS upload directory")?;
    let upload_export_path = Utf8PathBuf::from_path_buf(upload_dir.path().join("export"))
        .map_err(|path| anyhow!("non-UTF-8 temporary iOS upload export path: {path:?}"))?;
    fs::create_dir_all(upload_export_path.as_std_path())
        .with_context(|| format!("creating {upload_export_path}"))?;

    let upload_options =
        Utf8PathBuf::from_path_buf(upload_dir.path().join("ExportOptions-iOS-Upload.plist"))
            .map_err(|path| anyhow!("non-UTF-8 temporary iOS upload options path: {path:?}"))?;
    fs::copy(
        source_export_plist.as_std_path(),
        upload_options.as_std_path(),
    )
    .with_context(|| format!("copying {source_export_plist} to {upload_options}"))?;
    Runner::new(reporter, "/usr/libexec/PlistBuddy")
        .args([
            "-c",
            "Set :destination upload",
            "-c",
            "Add :manageAppVersionAndBuildNumber bool false",
        ])
        .arg(upload_options.as_std_path())
        .run()
        .with_context(|| format!("configuring iOS upload export options at {upload_options}"))?;

    reporter.info("Uploading iOS archive with xcodebuild destination=upload");
    Runner::new(reporter, "xcodebuild")
        .args(["-exportArchive", "-archivePath"])
        .arg(archive_path.as_std_path())
        .arg("-exportPath")
        .arg(upload_export_path.as_std_path())
        .arg("-exportOptionsPlist")
        .arg(upload_options.as_std_path())
        .arg("-authenticationKeyPath")
        .arg(asc_private_key_path.as_std_path())
        .arg("-authenticationKeyID")
        .arg(asc_key_id)
        .arg("-authenticationKeyIssuerID")
        .arg(asc_issuer_id)
        .cwd(repo.as_path())
        .sanitize_for_xcode()
        .run()?;

    Ok(())
}

/// States that block creating a new App Store version. ASC silently refuses
/// `versions create` while one of these is outstanding, surfacing a confusing
/// "App in current state" error instead.
///
/// They split into two classes. *Rejected* states are back in our hands — the
/// version isn't progressing anywhere on its own, so we recover automatically
/// by canceling its open review submission (see `recover_rejected_version`).
/// *In-flight* states are live in Apple's pipeline (queued, under review, or
/// approved and awaiting release); canceling those is a real product decision,
/// so we skip the publish and leave them for a human.
fn blocker_class(state: &str) -> Option<BlockerClass> {
    match state {
        "DEVELOPER_REJECTED" | "REJECTED" | "METADATA_REJECTED" => Some(BlockerClass::Rejected),
        "WAITING_FOR_REVIEW"
        | "IN_REVIEW"
        | "PENDING_DEVELOPER_RELEASE"
        | "PENDING_APPLE_RELEASE"
        | "PROCESSING_FOR_APP_STORE" => Some(BlockerClass::InFlight),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BlockerClass {
    /// Rejected by us or Apple; recoverable by canceling the open submission.
    Rejected,
    /// Live in Apple's review/release pipeline; only a human should intervene.
    InFlight,
}

/// Bail out early (before any binary upload or build work) if a prior App
/// Store version is locked in a state that would block creating a new version.
///
/// For *rejected* versions this clears the blocker in place by canceling the
/// open review submission, then returns `Ok` so the publish can proceed. For
/// *in-flight* versions it returns a `VersionLockedError`, which `publish`
/// turns into a friendly skip.
fn check_no_blocking_version(
    repo: &RepoRoot,
    platform: PublishPlatform,
    requested_version: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let recent = asc_json(
        repo,
        &[
            "versions",
            "list",
            "--app",
            platform.app_id,
            "--platform",
            platform.asc_platform,
            "--limit",
            "5",
        ],
        asc_env,
        reporter,
    )?;
    for entry in &recent {
        let state = entry
            .get("attributes")
            .and_then(|a| a.get("appStoreState"))
            .and_then(Value::as_str);
        let Some(class) = state.and_then(blocker_class) else {
            continue;
        };
        let version = entry
            .get("attributes")
            .and_then(|a| a.get("versionString"))
            .and_then(Value::as_str)
            .unwrap_or("?");
        match class {
            BlockerClass::Rejected => {
                reporter.info(&format!(
                    "Found {} version {version} in state {} (rejected); clearing it to publish {requested_version}...",
                    platform.label,
                    state.unwrap_or("?"),
                ));
                recover_rejected_version(repo, platform, asc_env, reporter)?;
                // The version is editable again (or will be recreated by
                // `ensure_editable_version`); nothing else blocks us.
                return Ok(());
            }
            BlockerClass::InFlight => {
                return Err(VersionLockedError {
                    version: version.to_string(),
                    state: state.unwrap_or("?").to_string(),
                    platform_label: platform.label,
                    requested_version: requested_version.to_string(),
                }
                .into());
            }
        }
    }
    Ok(())
}

/// Cancel the open review submission for `platform`, releasing a rejected
/// version back to `PREPARE_FOR_SUBMISSION` so a new build can be attached.
///
/// A rejected version still has a review submission attached on ASC's side;
/// until it is canceled, `versions create`/`update` keeps failing. There is at
/// most one open submission per app+platform, so we cancel every submission
/// that isn't already in a terminal state.
fn recover_rejected_version(
    repo: &RepoRoot,
    platform: PublishPlatform,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let submissions = asc_json(
        repo,
        &[
            "review",
            "submissions-list",
            "--app",
            platform.app_id,
            "--platform",
            platform.asc_platform,
        ],
        asc_env,
        reporter,
    )?;

    // ASC marks a submission terminal once it is canceled or fully processed;
    // those can't (and needn't) be canceled again.
    const TERMINAL: &[&str] = &["COMPLETING", "COMPLETE", "CANCELING", "CANCELED"];

    let mut canceled_any = false;
    for submission in &submissions {
        let state = submission
            .get("attributes")
            .and_then(|a| a.get("state"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if TERMINAL.contains(&state) {
            continue;
        }
        let id = submission
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("review submission entry missing id"))?;
        reporter.info(&format!(
            "Canceling {} review submission {id} (state {state})...",
            platform.label
        ));
        asc_command(
            repo,
            &["review", "submissions-cancel", "--id", id, "--confirm"],
            asc_env,
            reporter,
        )
        .with_context(|| format!("canceling review submission {id}"))?;
        canceled_any = true;
    }

    if !canceled_any {
        reporter.info(&format!(
            "No open {} review submission to cancel; version should already be editable.",
            platform.label
        ));
        return Ok(());
    }

    // Cancellation is asynchronous: the submission moves through CANCELING
    // before the rejected version flips back to an editable state. Creating
    // the new version too soon fails with "App in current state", so wait for
    // the blocker to clear before returning to `ensure_editable_version`.
    let deadline = Instant::now() + Duration::from_secs(180);
    loop {
        let still_blocked = asc_json(
            repo,
            &[
                "versions",
                "list",
                "--app",
                platform.app_id,
                "--platform",
                platform.asc_platform,
                "--limit",
                "5",
            ],
            asc_env,
            reporter,
        )?
        .iter()
        .any(|entry| {
            entry
                .get("attributes")
                .and_then(|a| a.get("appStoreState"))
                .and_then(Value::as_str)
                .and_then(blocker_class)
                .is_some()
        });
        if !still_blocked {
            reporter.info(&format!(
                "{} version is editable again after cancellation.",
                platform.label
            ));
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(anyhow!(
                "{} version still blocked 180s after canceling its review submission; \
                 ASC may need longer to process the cancellation. Re-run the publish.",
                platform.label
            ));
        }
        thread::sleep(Duration::from_secs(10));
    }
}

#[derive(Debug)]
struct VersionLockedError {
    version: String,
    state: String,
    platform_label: &'static str,
    requested_version: String,
}

impl std::fmt::Display for VersionLockedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "App Store version {} is in state {} for {}. \
             Resolve that version (cancel review, release, or address rejection) \
             before publishing {}.",
            self.version, self.state, self.platform_label, self.requested_version,
        )
    }
}

impl std::error::Error for VersionLockedError {}

/// Required per-locale fields for an App Store version. ASC blocks "Add for
/// Review" with an error like "<Locale> - <Field> - This field is required"
/// if any of these is missing for any locale present in the App Info.
const REQUIRED_LOCALE_FILES: &[&str] =
    &["description.txt", "release_notes.txt", "subtitle.txt"];

fn validate_metadata_locales(repo: &RepoRoot, platform: PublishPlatform) -> Result<()> {
    let metadata_dir = repo.join(format!("distribution/{}", platform.metadata_dir_name));
    if !metadata_dir.as_std_path().is_dir() {
        return Err(anyhow!(
            "metadata directory missing: {metadata_dir}"
        ));
    }
    let mut missing: Vec<String> = Vec::new();
    for entry in fs::read_dir(metadata_dir.as_std_path())
        .with_context(|| format!("listing {metadata_dir}"))?
    {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let dir_name = entry.file_name().to_string_lossy().to_string();
        // Skip helper dirs like `review_information`.
        if !looks_like_locale_dir(&dir_name) {
            continue;
        }
        for required in REQUIRED_LOCALE_FILES {
            let path = entry.path().join(required);
            if !path.is_file() {
                missing.push(format!("{dir_name}/{required}"));
            }
        }
    }
    if !missing.is_empty() {
        return Err(anyhow!(
            "App Store metadata is missing required per-locale files: {}. \
             Add the missing files under distribution/{} before publishing — \
             ASC will refuse to submit the version otherwise.",
            missing.join(", "),
            platform.metadata_dir_name,
        ));
    }
    Ok(())
}

fn looks_like_locale_dir(name: &str) -> bool {
    // Apple locale codes follow ISO-639 + optional region/script suffix:
    //   en-US, fr-FR, ja, zh-Hans, pt-BR, cs.
    // The full string is always two lowercase letters, optionally followed by
    // `-` and at least one letter (no underscores, no whitespace, no
    // additional `-` segments). This intentionally rejects helper directories
    // like `review_information`.
    let bytes = name.as_bytes();
    if bytes.len() < 2 || !bytes[0].is_ascii_lowercase() || !bytes[1].is_ascii_lowercase() {
        return false;
    }
    if bytes.len() == 2 {
        return true;
    }
    if bytes[2] != b'-' || bytes.len() == 3 {
        return false;
    }
    bytes[3..].iter().all(|b| b.is_ascii_alphabetic())
}

/// After uploading the IPA/PKG and finding the editable App Store version,
/// attach the latest VALID build for that version string. ASC otherwise
/// requires the human to pick a build in the web UI before submitting,
/// which silently blocks the release.
fn attach_latest_valid_build(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version: &str,
    version_id: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    // Best build for the version is the most recently uploaded one whose
    // processing state is VALID. ASC's binary upload happens just before this
    // step, but Apple's processing can take longer than the upload itself.
    //
    // ClipKitty's macOS and iOS apps share one app_id, so we MUST filter by
    // platform server-side — otherwise an iOS build with the same version
    // string will be returned and `versions attach-build` rejects it with
    // "The specified build has a different platform than the version."
    let deadline = Instant::now() + ASC_BUILD_PROCESSING_TIMEOUT;
    let mut last_seen_state: Option<String> = None;
    let build_id = loop {
        let builds = asc_json(
            repo,
            &[
                "builds",
                "list",
                "--app",
                platform.app_id,
                "--platform",
                platform.asc_platform,
                "--version",
                version,
                "--limit",
                "20",
            ],
            asc_env,
            reporter,
        )?;
        // Sort by uploadedDate descending, then take the first VALID one.
        let mut candidates: Vec<&Value> = builds
            .iter()
            .filter(|b| {
                b.get("attributes")
                    .and_then(|a| a.get("platform"))
                    .and_then(Value::as_str)
                    .is_none_or(|p| p.eq_ignore_ascii_case(platform.asc_platform))
            })
            .collect();
        candidates.sort_by(|a, b| {
            let date_a = a
                .get("attributes")
                .and_then(|attrs| attrs.get("uploadedDate"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let date_b = b
                .get("attributes")
                .and_then(|attrs| attrs.get("uploadedDate"))
                .and_then(Value::as_str)
                .unwrap_or("");
            date_b.cmp(date_a)
        });
        let valid = candidates.iter().find(|b| {
            b.get("attributes")
                .and_then(|a| a.get("processingState"))
                .and_then(Value::as_str)
                == Some("VALID")
        });
        if let Some(build) = valid {
            if let Some(id) = build.get("id").and_then(Value::as_str) {
                break id.to_string();
            }
        }
        // Track the most recent build's state for diagnostics.
        if let Some(top) = candidates.first() {
            last_seen_state = top
                .get("attributes")
                .and_then(|a| a.get("processingState"))
                .and_then(Value::as_str)
                .map(|s| s.to_string());
        }
        if Instant::now() >= deadline {
            return Err(anyhow!(
                "no VALID {} build found within {} minutes (latest seen: {})",
                platform.label,
                ASC_BUILD_PROCESSING_TIMEOUT.as_secs() / 60,
                last_seen_state.as_deref().unwrap_or("not listed yet")
            ));
        }
        reporter.info(&format!(
            "Waiting for {} build to finish processing (last seen: {})...",
            platform.label,
            last_seen_state.as_deref().unwrap_or("not listed yet")
        ));
        thread::sleep(ASC_BUILD_PROCESSING_POLL_INTERVAL);
    };

    reporter.info(&format!(
        "Attaching latest VALID {} build {build_id} to version {version_id}...",
        platform.label
    ));
    asc_command(
        repo,
        &[
            "versions",
            "attach-build",
            "--version-id",
            version_id,
            "--build",
            &build_id,
        ],
        asc_env,
        reporter,
    )?;
    Ok(())
}

/// A pre-release version that ASC will let us edit in place (change its build,
/// version string, and release type) but which blocks `versions create`.
struct ReusableVersion {
    id: String,
    version_string: String,
}

/// Find an existing version that is rejected (back in our hands) so we can
/// repurpose it instead of creating a new one. `recover_rejected_version` has
/// already canceled any open review submission; whatever rejected version
/// remains is editable in place. There is at most one such pre-release version
/// per app+platform, so we return the first match.
fn find_reusable_rejected_version(
    repo: &RepoRoot,
    platform: PublishPlatform,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<Option<ReusableVersion>> {
    let recent = asc_json(
        repo,
        &[
            "versions",
            "list",
            "--app",
            platform.app_id,
            "--platform",
            platform.asc_platform,
            "--limit",
            "5",
        ],
        asc_env,
        reporter,
    )?;
    for entry in &recent {
        let attrs = entry.get("attributes");
        let state = attrs
            .and_then(|a| a.get("appStoreState"))
            .and_then(Value::as_str);
        if state.and_then(blocker_class) != Some(BlockerClass::Rejected) {
            continue;
        }
        let id = entry
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("version list entry missing id"))?;
        let version_string = attrs
            .and_then(|a| a.get("versionString"))
            .and_then(Value::as_str)
            .unwrap_or("?");
        return Ok(Some(ReusableVersion {
            id: id.to_string(),
            version_string: version_string.to_string(),
        }));
    }
    Ok(None)
}

fn ensure_editable_version(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<String> {
    // Defense in depth: even though `publish` calls
    // `check_no_blocking_version` up front, re-check here so direct
    // callers of `ensure_editable_version` don't get a confusing
    // "App in current state" error from `versions create`.
    check_no_blocking_version(repo, platform, version, asc_env, reporter)?;

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
            reporter.info(&format!(
                "Using existing App Store version {version} (ID: {existing_id})"
            ));
            reporter.info(&format!("Target version ID: {existing_id}"));
            return Ok(existing_id.to_string());
        }

        reporter.info(&format!(
            "Updating existing PREPARE_FOR_SUBMISSION version {existing_version} (ID: {existing_id}) to {version}..."
        ));
        let id = update_app_store_version(repo, existing_id, version, asc_env, reporter)
            .with_context(|| {
                format!(
                    "updating existing App Store version {existing_version} (ID: {existing_id}) to {version}"
                )
            })?;
        reporter.info(&format!("Target version ID: {id}"));
        return Ok(id);
    }

    // No PREPARE_FOR_SUBMISSION version exists. A version that is rejected but
    // has no open review submission to cancel (e.g. DEVELOPER_REJECTED after
    // the submission already processed) stays in that state — it is editable in
    // ASC's UI but `versions create` refuses to add a *second* pre-release
    // version while it occupies the editable slot ("App in current state").
    // `recover_rejected_version` already tried to cancel its submission and
    // found none, so reuse the version in place: point it at the new version
    // string and release type instead of creating a fresh one.
    if let Some(reusable) = find_reusable_rejected_version(repo, platform, asc_env, reporter)? {
        reporter.info(&format!(
            "Reusing rejected App Store version {} (ID: {}) for {version}...",
            reusable.version_string, reusable.id
        ));
        let id = update_app_store_version(repo, &reusable.id, version, asc_env, reporter)
            .with_context(|| {
                format!(
                    "reusing rejected App Store version {} (ID: {}) for {version}",
                    reusable.version_string, reusable.id
                )
            })?;
        reporter.info(&format!("Target version ID: {id}"));
        return Ok(id);
    }

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
            RELEASE_TYPE,
        ],
        asc_env,
        reporter,
    )
    .with_context(|| {
        format!(
            "creating editable App Store version {version}; metadata, screenshots, and preview videos were not uploaded"
        )
    })?;
    let created = parse_asc_data(&output.stdout)?;
    let id = created
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("created version response missing id"))?;
    reporter.info(&format!("Created version {version} (ID: {id})"));
    reporter.info(&format!("Target version ID: {id}"));
    Ok(id.to_string())
}

fn update_app_store_version(
    repo: &RepoRoot,
    version_id: &str,
    version: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<String> {
    let output = asc_command(
        repo,
        &[
            "versions",
            "update",
            "--version-id",
            version_id,
            "--version",
            version,
            "--release-type",
            RELEASE_TYPE,
        ],
        asc_env,
        reporter,
    )?;
    let updated = parse_asc_data(&output.stdout)?;
    let id = updated
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or(version_id);
    reporter.info(&format!("Updated App Store version {version} (ID: {id})"));
    Ok(id.to_string())
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

fn is_transient_asc_auth_error(err: &anyhow::Error) -> bool {
    let msg = err.to_string();
    msg.contains("Authentication credentials are missing or invalid")
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

    let mut uploaded_count = 0usize;
    let marketing_dir = repo.join(platform.marketing_dir_name);
    if !marketing_dir.as_std_path().is_dir() {
        return Err(anyhow!(
            "marketing directory not found: {marketing_dir}; generate or download {} screenshots before publishing",
            platform.label
        ));
    }

    for (source_locale, asc_locale) in LOCALE_MAP {
        let Some(localization_id) = locale_to_id.get(*asc_locale) else {
            return Err(anyhow!(
                "no ASC localization for {asc_locale}; cannot upload {} screenshots",
                platform.label
            ));
        };

        let locale_dir = marketing_dir.join(source_locale);
        let pngs = expected_screenshot_paths(&locale_dir, *asc_locale, platform.label)?;

        for device_type in platform.screenshot_device_types {
            // Up to 3 attempts: ASC's flaky 401s can leave the set with the
            // wrong number of screenshots (partial uploads, duplicates from
            // retried 401-then-success calls). Retry the whole replace+upload
            // sequence until the set count matches the expected file count.
            let expected = pngs.len();
            let mut last_error: Option<anyhow::Error> = None;
            let mut succeeded = false;
            for attempt in 1..=3 {
                if let Err(err) = (|| -> Result<()> {
                    clear_existing_screenshots_for_device(
                        repo,
                        localization_id,
                        *asc_locale,
                        device_type,
                        asc_env,
                        reporter,
                    )?;
                    reporter.info(&format!(
                        "Replacing with {expected} {device_type} screenshots for {asc_locale} (attempt {attempt})...",
                    ));
                    for (index, png) in pngs.iter().enumerate() {
                        let upload_mode = if index == 0 {
                            ScreenshotUploadMode::ReplaceTargetSet
                        } else {
                            ScreenshotUploadMode::AppendAfterReplace
                        };
                        let mut args = vec![
                            "screenshots",
                            "upload",
                            "--version-localization",
                            localization_id,
                            "--device-type",
                            device_type,
                            "--path",
                            png.as_str(),
                        ];
                        match upload_mode {
                            ScreenshotUploadMode::ReplaceTargetSet => args.push("--replace"),
                            ScreenshotUploadMode::AppendAfterReplace => {}
                        }
                        asc_command(repo, &args, asc_env, reporter)?;
                    }
                    Ok(())
                })() {
                    last_error = Some(err);
                } else {
                    // Allow up to ~30s for ASC to flip newly-uploaded
                    // screenshots from AWAITING_UPLOAD to COMPLETE before
                    // declaring this attempt failed and clearing+reuploading.
                    match wait_for_screenshot_set_ready(
                        repo,
                        localization_id,
                        device_type,
                        expected,
                        asc_env,
                        reporter,
                    )? {
                        Ok(()) => {
                            succeeded = true;
                            break;
                        }
                        Err(reason) => {
                            last_error = Some(anyhow!("{device_type} {asc_locale}: {reason}"));
                            reporter.info(&format!(
                                "Screenshot upload not yet ready for {device_type} {asc_locale} ({reason}); retrying..."
                            ));
                        }
                    }
                }
            }
            if !succeeded {
                return Err(last_error
                    .unwrap_or_else(|| anyhow!("screenshot upload failed without error")));
            }
            uploaded_count += expected;
        }
    }

    reporter.info(&format!("Total screenshots uploaded: {uploaded_count}"));
    Ok(())
}

/// Poll the screenshot set for up to ~3m, returning `Ok(())` once it has
/// `expected` screenshots and all of them are `COMPLETE`. Returns
/// `Err(reason)` if the deadline passes without that state being reached.
///
/// This catches stuck `AWAITING_UPLOAD` screenshots that never finished
/// (typical when ASC 401s the post-upload status subrequest). Without this,
/// the release would succeed locally but the user would later see an
/// "Add for Review" gate complaining about uploads still in progress.
fn wait_for_screenshot_set_ready(
    repo: &RepoRoot,
    localization_id: &str,
    device_type: &str,
    expected: usize,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<std::result::Result<(), String>> {
    let deadline = Instant::now() + Duration::from_secs(180);
    loop {
        let screenshots =
            list_screenshot_set(repo, localization_id, device_type, asc_env, reporter)?;
        let actual = screenshots.len();
        let pending = screenshots
            .iter()
            .filter(|ss| screenshot_state(ss) != Some("COMPLETE"))
            .count();
        if actual == expected && pending == 0 {
            return Ok(Ok(()));
        }
        let reason = if actual != expected {
            format!("expected {expected} screenshots, found {actual}")
        } else {
            format!("{pending} of {actual} screenshot(s) still uploading")
        };
        if Instant::now() >= deadline {
            return Ok(Err(reason));
        }
        thread::sleep(Duration::from_secs(5));
    }
}

/// `asc screenshots list` returns
///   { "sets": [ { "set": {...}, "screenshots": [...] }, ... ] }
/// rather than the standard ASC `data` envelope, so parse the inner shape
/// directly. Returns the screenshots for `device_type`, or an empty vec
/// if no set exists for that device type yet.
fn list_screenshot_set(
    repo: &RepoRoot,
    localization_id: &str,
    device_type: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<Vec<Value>> {
    let output = asc_command(
        repo,
        &[
            "screenshots",
            "list",
            "--version-localization",
            localization_id,
        ],
        asc_env,
        reporter,
    )?;
    let parsed: Value =
        serde_json::from_slice(&output.stdout).context("parsing asc screenshots list JSON")?;
    let Some(sets) = parsed.get("sets").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    for entry in sets {
        let entry_device_type = entry
            .get("set")
            .and_then(|s| s.get("attributes"))
            .and_then(|a| a.get("screenshotDisplayType"))
            .and_then(Value::as_str);
        if screenshot_display_type_matches(entry_device_type, device_type) {
            return Ok(entry
                .get("screenshots")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default());
        }
    }
    Ok(Vec::new())
}

fn screenshot_display_type_matches(actual: Option<&str>, expected: &str) -> bool {
    actual.is_some_and(|actual| {
        normalize_screenshot_display_type(actual) == normalize_screenshot_display_type(expected)
    })
}

fn normalize_screenshot_display_type(display_type: &str) -> &str {
    display_type
        .strip_prefix("APP_")
        .unwrap_or(display_type)
}

fn screenshot_state(screenshot: &Value) -> Option<&str> {
    screenshot
        .get("attributes")?
        .get("assetDeliveryState")?
        .get("state")?
        .as_str()
}

fn screenshot_id(screenshot: &Value) -> Option<&str> {
    screenshot.get("id")?.as_str()
}

fn clear_existing_screenshots_for_device(
    repo: &RepoRoot,
    localization_id: &str,
    asc_locale: &str,
    device_type: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let screenshots = list_screenshot_set(repo, localization_id, device_type, asc_env, reporter)?;
    if screenshots.is_empty() {
        return Ok(());
    }

    reporter.info(&format!(
        "Clearing {} existing {device_type} screenshots for {asc_locale}...",
        screenshots.len()
    ));
    for screenshot in &screenshots {
        let Some(id) = screenshot_id(screenshot) else {
            continue;
        };
        asc_command(
            repo,
            &["screenshots", "delete", "--id", id, "--confirm"],
            asc_env,
            reporter,
        )?;
    }
    Ok(())
}

fn expected_screenshot_paths(
    locale_dir: &Utf8Path,
    asc_locale: &str,
    platform_label: &str,
) -> Result<Vec<Utf8PathBuf>> {
    if !locale_dir.as_std_path().is_dir() {
        return Err(anyhow!(
            "missing {platform_label} screenshot directory for {asc_locale}: {locale_dir}"
        ));
    }

    let mut paths = Vec::with_capacity(EXPECTED_SCREENSHOT_FILES.len());
    for filename in EXPECTED_SCREENSHOT_FILES {
        let path = locale_dir.join(filename);
        if !path.as_std_path().is_file() {
            return Err(anyhow!(
                "missing {platform_label} screenshot for {asc_locale}: {path}"
            ));
        }
        paths.push(path);
    }
    Ok(paths)
}

enum ScreenshotUploadMode {
    ReplaceTargetSet,
    AppendAfterReplace,
}

fn upload_app_previews(
    repo: &RepoRoot,
    platform: PublishPlatform,
    version_id: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let locale_to_id = version_locale_ids(repo, version_id, asc_env, reporter)?;
    let marketing_dir = repo.join(platform.marketing_dir_name);
    if !marketing_dir.as_std_path().is_dir() {
        return Err(anyhow!(
            "marketing directory not found: {marketing_dir}; run `make intro-video` before publishing {} app previews",
            platform.label
        ));
    }

    let mut uploaded = Vec::new();
    for (source_locale, asc_locale) in LOCALE_MAP {
        let Some(localization_id) = locale_to_id.get(*asc_locale) else {
            return Err(anyhow!(
                "no ASC localization for {asc_locale}; cannot upload {} app preview video",
                platform.label
            ));
        };

        let video = marketing_dir.join(format!("{source_locale}/intro_video.mov"));
        if !video.as_std_path().is_file() {
            return Err(anyhow!(
                "missing localized app preview video for {asc_locale}: {video}; run `make intro-video` before publishing"
            ));
        }

        for preview_type in platform.preview_device_types {
            clear_existing_app_previews_for_device(
                repo,
                localization_id,
                *asc_locale,
                preview_type,
                asc_env,
                reporter,
            )?;
            reporter.info(&format!(
                "Replacing {preview_type} app preview for {asc_locale} with {video}..."
            ));
            let output = upload_app_preview_with_retry(
                repo,
                localization_id,
                asc_locale,
                preview_type,
                &video,
                asc_env,
                reporter,
            )?;
            let preview_ids = parse_asc_data(&output.stdout)
                .map(|data| collect_ids(&data))
                .unwrap_or_default();
            uploaded.push(UploadedAppPreview {
                localization_id: localization_id.clone(),
                asc_locale: (*asc_locale).to_string(),
                preview_type: (*preview_type).to_string(),
                expected_ids: preview_ids,
            });
        }
    }

    if uploaded.is_empty() {
        reporter.info("No app preview videos uploaded.");
        return Ok(());
    }

    wait_for_app_previews(repo, &uploaded, asc_env, reporter)?;
    reporter.info(&format!(
        "Total app preview videos uploaded: {}",
        uploaded.len()
    ));
    Ok(())
}

fn clear_existing_app_previews_for_device(
    repo: &RepoRoot,
    localization_id: &str,
    asc_locale: &str,
    preview_type: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let previews = asc_json(
        repo,
        &[
            "video-previews",
            "list",
            "--version-localization",
            localization_id,
        ],
        asc_env,
        reporter,
    )?;
    let ids = media_ids_with_attribute(
        &previews,
        "appPreviews",
        &["previewType", "appPreviewType"],
        preview_type,
    );
    if ids.is_empty() {
        return Ok(());
    }

    reporter.info(&format!(
        "Clearing {} existing {preview_type} app preview videos for {asc_locale}...",
        ids.len()
    ));
    for id in ids {
        asc_command(
            repo,
            &["video-previews", "delete", "--id", &id, "--confirm"],
            asc_env,
            reporter,
        )?;
    }
    Ok(())
}

fn upload_app_preview_with_retry(
    repo: &RepoRoot,
    localization_id: &str,
    asc_locale: &str,
    preview_type: &str,
    video: &Utf8Path,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<crate::process::CommandOutput> {
    let started = Instant::now();
    let timeout = Duration::from_secs(30 * 60);
    loop {
        let args = [
            "video-previews",
            "upload",
            "--version-localization",
            localization_id,
            "--device-type",
            preview_type,
            "--path",
            video.as_str(),
            "--replace",
        ];
        let output = asc_command_output(repo, &args, asc_env, reporter)?;
        if output.status.success() {
            return Ok(output);
        }

        let output_text = command_output_text(&output);
        if !is_preview_upload_in_progress_error(&output_text) {
            return Err(anyhow!("`asc {}` failed: {}", args.join(" "), output_text));
        }

        if started.elapsed() >= timeout {
            return Err(anyhow!(
                "timed out waiting to replace {asc_locale} {preview_type} app preview: {}",
                output_text
            ));
        }

        reporter.info(&format!(
            "{asc_locale} {preview_type} preview upload is blocked by an existing ASC upload; waiting before retry..."
        ));
        wait_for_blocking_app_previews(
            repo,
            localization_id,
            asc_locale,
            preview_type,
            asc_env,
            reporter,
        )?;
    }
}

fn wait_for_blocking_app_previews(
    repo: &RepoRoot,
    localization_id: &str,
    asc_locale: &str,
    preview_type: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let timeout = Duration::from_secs(30 * 60);
    let poll_interval = Duration::from_secs(30);
    let started = Instant::now();

    loop {
        let previews = asc_json(
            repo,
            &[
                "video-previews",
                "list",
                "--version-localization",
                localization_id,
            ],
            asc_env,
            reporter,
        )?;
        let mut pending = Vec::new();
        for preview in &previews {
            match app_preview_state(preview) {
                AppPreviewState::Ready => {}
                AppPreviewState::Pending(summary) => pending.push(summary),
                AppPreviewState::Failed(summary) => {
                    return Err(anyhow!(
                        "{asc_locale} {preview_type} existing app preview processing failed: {summary}"
                    ));
                }
            }
        }

        if pending.is_empty() {
            return Ok(());
        }

        if started.elapsed() >= timeout {
            return Err(anyhow!(
                "timed out waiting for blocking {asc_locale} {preview_type} app preview uploads: {}",
                pending.join("; ")
            ));
        }

        reporter.info(&format!(
            "Waiting for blocking {asc_locale} {preview_type} app preview uploads: {}",
            pending.join("; ")
        ));
        thread::sleep(poll_interval);
    }
}

fn is_preview_upload_in_progress_error(message: &str) -> bool {
    message.contains("There are still preview uploads in progress")
}

struct UploadedAppPreview {
    localization_id: String,
    asc_locale: String,
    preview_type: String,
    expected_ids: Vec<String>,
}

fn wait_for_app_previews(
    repo: &RepoRoot,
    uploaded: &[UploadedAppPreview],
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<()> {
    let timeout = Duration::from_secs(30 * 60);
    let poll_interval = Duration::from_secs(30);
    let started = Instant::now();

    loop {
        let mut pending = Vec::new();
        for target in uploaded {
            let previews = asc_json(
                repo,
                &[
                    "video-previews",
                    "list",
                    "--version-localization",
                    &target.localization_id,
                ],
                asc_env,
                reporter,
            )?;
            let matching_previews = previews
                .iter()
                .filter(|preview| preview_matches_upload(target, preview))
                .collect::<Vec<_>>();

            if matching_previews.is_empty() {
                pending.push(format!(
                    "{} {} has not appeared in ASC yet",
                    target.asc_locale, target.preview_type
                ));
                continue;
            }

            for preview in matching_previews {
                match app_preview_state(preview) {
                    AppPreviewState::Ready => {}
                    AppPreviewState::Pending(summary) => pending.push(format!(
                        "{} {} is still processing ({summary})",
                        target.asc_locale, target.preview_type
                    )),
                    AppPreviewState::Failed(summary) => {
                        return Err(anyhow!(
                            "{} {} app preview processing failed: {summary}",
                            target.asc_locale,
                            target.preview_type
                        ));
                    }
                }
            }
        }

        if pending.is_empty() {
            reporter.info("All app preview videos finished processing.");
            return Ok(());
        }

        if started.elapsed() >= timeout {
            reporter.info(&format!(
                "Warning: timed out waiting for app preview processing; ASC accepted the uploads but has not reported delivery states yet: {}",
                pending.join("; ")
            ));
            return Ok(());
        }

        reporter.info(&format!(
            "Waiting for app preview processing: {}",
            pending.join("; ")
        ));
        thread::sleep(poll_interval);
    }
}

fn preview_matches_upload(target: &UploadedAppPreview, preview: &Value) -> bool {
    if target.expected_ids.is_empty() {
        return true;
    }
    preview
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|id| target.expected_ids.iter().any(|expected| expected == id))
}

enum AppPreviewState {
    Ready,
    Pending(String),
    Failed(String),
}

fn app_preview_state(preview: &Value) -> AppPreviewState {
    let states = app_preview_delivery_states(preview);
    if states.asset.is_empty() && states.video.is_empty() {
        return AppPreviewState::Pending("ASC has not reported delivery states yet".to_string());
    }

    let summary = states.summary();
    if states
        .asset
        .iter()
        .chain(states.video.iter())
        .any(|state| state.contains("FAIL") || state.contains("ERROR") || state.contains("INVALID"))
    {
        return AppPreviewState::Failed(summary);
    }

    if states
        .asset
        .iter()
        .all(|state| is_finished_delivery_state(state))
        && !states.video.is_empty()
        && states
            .video
            .iter()
            .all(|state| is_finished_delivery_state(state))
    {
        return AppPreviewState::Ready;
    }

    AppPreviewState::Pending(summary)
}

struct AppPreviewDeliveryStates {
    asset: Vec<String>,
    video: Vec<String>,
}

impl AppPreviewDeliveryStates {
    fn summary(&self) -> String {
        let mut parts = Vec::new();
        if self.asset.is_empty() {
            parts.push("assetDeliveryState: missing".to_string());
        } else {
            parts.push(format!("assetDeliveryState: {}", self.asset.join(", ")));
        }
        if self.video.is_empty() {
            parts.push("videoDeliveryState: missing".to_string());
        } else {
            parts.push(format!("videoDeliveryState: {}", self.video.join(", ")));
        }
        parts.join("; ")
    }
}

fn app_preview_delivery_states(preview: &Value) -> AppPreviewDeliveryStates {
    let mut asset = Vec::new();
    let mut video = Vec::new();
    if let Some(attrs) = preview.get("attributes") {
        collect_named_states(attrs, "assetDeliveryState", &mut asset);
        collect_named_states(attrs, "videoDeliveryState", &mut video);
    }
    asset.sort();
    asset.dedup();
    video.sort();
    video.dedup();
    AppPreviewDeliveryStates { asset, video }
}

fn is_finished_delivery_state(state: &str) -> bool {
    matches!(state, "COMPLETE" | "READY" | "DELIVERED" | "ACCEPTED")
}

fn collect_named_states(value: &Value, key: &str, states: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            if let Some(named) = map.get(key) {
                collect_state_values(named, states);
            }
            for child in map.values() {
                collect_named_states(child, key, states);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_named_states(item, key, states);
            }
        }
        _ => {}
    }
}

fn collect_state_values(value: &Value, states: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            if let Some(state) = map.get("state").and_then(Value::as_str) {
                states.push(state.to_ascii_uppercase());
            }
            for child in map.values() {
                collect_state_values(child, states);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_state_values(item, states);
            }
        }
        Value::String(state) => states.push(state.to_ascii_uppercase()),
        _ => {}
    }
}

fn media_ids_with_attribute(
    items: &[Value],
    type_name: &str,
    attribute_names: &[&str],
    expected_value: &str,
) -> Vec<String> {
    let mut ids = Vec::new();
    for item in items {
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            continue;
        };
        if item.get("type").and_then(Value::as_str) != Some(type_name) {
            continue;
        }
        let Some(attributes) = item.get("attributes") else {
            continue;
        };
        let matches_expected = attribute_names.iter().any(|name| {
            attributes
                .get(*name)
                .and_then(Value::as_str)
                .is_some_and(|value| value == expected_value)
        });
        if matches_expected {
            ids.push(id.to_string());
        }
    }
    ids
}

fn version_locale_ids(
    repo: &RepoRoot,
    version_id: &str,
    asc_env: &[(&str, &str)],
    reporter: &Reporter,
) -> Result<BTreeMap<String, String>> {
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
    Ok(locale_to_id)
}

fn collect_ids(value: &Value) -> Vec<String> {
    match value {
        Value::Object(map) => {
            let mut ids = Vec::new();
            if map.get("type").and_then(Value::as_str) == Some("appPreviews") {
                if let Some(id) = map.get("id").and_then(Value::as_str) {
                    ids.push(id.to_string());
                }
            }
            for child in map.values() {
                ids.extend(collect_ids(child));
            }
            ids
        }
        Value::Array(items) => items.iter().flat_map(collect_ids).collect(),
        _ => Vec::new(),
    }
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
    // ASC's API frequently 401s a single subrequest mid-call ("Authentication
    // credentials are missing or invalid") even though the JWT we just minted
    // is fine — the very next call with a fresh token works. Retry up to a
    // few times with growing backoff to absorb the spurious failures.
    const MAX_AUTH_RETRIES: usize = 3;
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 0..=MAX_AUTH_RETRIES {
        let output = asc_command_output(repo, args, asc_env, reporter)?;
        if output.status.success() {
            return Ok(output);
        }
        let combined = command_output_text(&output);
        let err = anyhow!("`asc {}` failed: {combined}", args.join(" "));
        if attempt < MAX_AUTH_RETRIES && is_transient_asc_auth_error(&err) {
            let backoff = Duration::from_secs(2u64.pow(attempt as u32 + 1));
            reporter.info(&format!(
                "ASC returned a transient auth failure, retrying in {}s ({}/{})...",
                backoff.as_secs(),
                attempt + 1,
                MAX_AUTH_RETRIES,
            ));
            thread::sleep(backoff);
            last_err = Some(err);
            continue;
        }
        return Err(err);
    }
    Err(last_err.unwrap_or_else(|| anyhow!("`asc {}` failed after retries", args.join(" "))))
}

fn asc_command_output(
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
    Ok(output)
}

fn command_output_text(output: &crate::process::CommandOutput) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("{stdout}{stderr}").trim().to_string()
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

    let resolved = version::resolve(repo, reporter)?;
    sign::sign_app(
        repo,
        &sign::SignAppRequest {
            variant: MacVariant::SparkleRelease,
            version: Some(resolved.version),
            build_number: Some(resolved.build_number),
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
            "[dry-run] would update {} ({}) → v{} ({}) @ {} ({} bytes)",
            args.state_path,
            args.channel.as_str(),
            args.version,
            args.build_number,
            args.url,
            args.length
        ));
        return Ok(());
    }

    let mut state = read_appcast_state(&args.state_path)?;
    let entry = AppcastRelease {
        version: args.version.clone(),
        build_number: Some(args.build_number.clone()),
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
    #[serde(default)]
    build_number: Option<String>,
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
    let build_number = appcast_build_number(release)?;
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
        xml_escape(&build_number)
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

fn appcast_build_number(release: &AppcastRelease) -> Result<String> {
    if let Some(build_number) = release
        .build_number
        .as_deref()
        .filter(|build_number| !build_number.is_empty())
    {
        return Ok(build_number.to_string());
    }

    release
        .version
        .rsplit('.')
        .next()
        .filter(|candidate| !candidate.is_empty())
        .filter(|candidate| candidate.chars().all(|c| c.is_ascii_digit()))
        .map(ToString::to_string)
        .ok_or_else(|| {
            anyhow!(
                "appcast release version `{}` does not contain an inferable build number",
                release.version
            )
        })
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

#[cfg(test)]
mod tests {
    use super::{
        app_preview_state, appcast_build_number, collect_ids, is_preview_upload_in_progress_error,
        looks_like_locale_dir, media_ids_with_attribute, render_appcast_xml,
        screenshot_display_type_matches, AppPreviewState, AppcastRelease, AppcastState,
        IOS_PLATFORM,
    };
    use serde_json::json;

    fn appcast_release(version: &str, build_number: Option<&str>) -> AppcastRelease {
        AppcastRelease {
            version: version.to_string(),
            build_number: build_number.map(ToString::to_string),
            url: "https://example.com/ClipKitty.dmg".to_string(),
            signature: "signature".to_string(),
            length: 1234,
            published_at: "2026-06-06T00:00:00Z".to_string(),
        }
    }

    #[test]
    fn appcast_uses_build_number_for_sparkle_version() {
        let xml = render_appcast_xml(&AppcastState {
            beta: None,
            stable: Some(appcast_release("1.13.1342", Some("1342"))),
        })
        .expect("render appcast");

        assert!(xml.contains("<sparkle:version>1342</sparkle:version>"));
        assert!(xml.contains("<sparkle:shortVersionString>1.13.1342</sparkle:shortVersionString>"));
    }

    #[test]
    fn appcast_infers_build_number_for_legacy_state() {
        let release = appcast_release("1.12.2317", None);

        assert_eq!(appcast_build_number(&release).unwrap(), "2317");
    }

    #[test]
    fn looks_like_locale_dir_accepts_apple_locale_codes() {
        assert!(looks_like_locale_dir("en-US"));
        assert!(looks_like_locale_dir("ja"));
        assert!(looks_like_locale_dir("zh-Hans"));
        assert!(looks_like_locale_dir("pt-BR"));
        assert!(looks_like_locale_dir("cs"));
        // Helper directories should be rejected so we don't insist on a
        // localized release_notes.txt under e.g. review_information/.
        assert!(!looks_like_locale_dir("review_information"));
        assert!(!looks_like_locale_dir("Review_Info"));
        assert!(!looks_like_locale_dir(""));
        assert!(!looks_like_locale_dir("E"));
    }

    #[test]
    fn app_preview_state_waits_for_processing_video() {
        let preview = json!({
            "type": "appPreviews",
            "id": "preview-1",
            "attributes": {
                "assetDeliveryState": { "state": "COMPLETE" },
                "videoDeliveryState": { "state": "PROCESSING" }
            }
        });

        let AppPreviewState::Pending(summary) = app_preview_state(&preview) else {
            panic!("expected pending preview state");
        };
        assert!(summary.contains("PROCESSING"));
    }

    #[test]
    fn app_preview_state_requires_video_delivery_state() {
        let preview = json!({
            "type": "appPreviews",
            "id": "preview-1",
            "attributes": {
                "assetDeliveryState": { "state": "UPLOAD_COMPLETE" }
            }
        });

        let AppPreviewState::Pending(summary) = app_preview_state(&preview) else {
            panic!("expected pending preview state");
        };
        assert!(summary.contains("videoDeliveryState: missing"));
    }

    #[test]
    fn app_preview_state_fails_on_delivery_error() {
        let preview = json!({
            "type": "appPreviews",
            "id": "preview-1",
            "attributes": {
                "assetDeliveryState": { "state": "FAILED" },
                "videoDeliveryState": { "state": "PROCESSING" }
            }
        });

        let AppPreviewState::Failed(summary) = app_preview_state(&preview) else {
            panic!("expected failed preview state");
        };
        assert!(summary.contains("FAILED"));
    }

    #[test]
    fn collect_ids_only_returns_app_preview_ids() {
        let response = json!({
            "data": {
                "type": "appPreviewSets",
                "id": "set-1",
                "relationships": {
                    "appPreviews": {
                        "data": [
                            { "type": "appPreviews", "id": "preview-1" }
                        ]
                    }
                }
            }
        });

        assert_eq!(collect_ids(&response), vec!["preview-1".to_string()]);
    }

    #[test]
    fn detects_blocking_preview_upload_message() {
        assert!(is_preview_upload_in_progress_error(
            "Error: There are still preview uploads in progress."
        ));
    }

    #[test]
    fn media_ids_with_attribute_filters_by_type_and_attribute() {
        let media = vec![
            json!(
            {
                "type": "appScreenshots",
                "id": "screenshot-1",
                "attributes": { "screenshotDisplayType": "DESKTOP" }
            }),
            json!(
            {
                "type": "appScreenshots",
                "id": "screenshot-2",
                "attributes": { "screenshotDisplayType": "IPHONE_65" }
            }),
            json!(
            {
                "type": "appPreviews",
                "id": "preview-1",
                "attributes": { "previewType": "DESKTOP" }
            }),
        ];

        assert_eq!(
            media_ids_with_attribute(
                &media,
                "appScreenshots",
                &["screenshotDisplayType"],
                "DESKTOP"
            ),
            vec!["screenshot-1".to_string()]
        );
    }

    #[test]
    fn ios_screenshots_upload_to_iphone_61_slot() {
        assert_eq!(IOS_PLATFORM.marketing_dir_name, "marketing-ios");
        assert_eq!(IOS_PLATFORM.screenshot_device_types, &["IPHONE_61"]);
    }

    #[test]
    fn screenshot_display_type_matches_app_store_prefix_variants() {
        assert!(screenshot_display_type_matches(
            Some("APP_IPHONE_61"),
            "IPHONE_61"
        ));
        assert!(screenshot_display_type_matches(
            Some("IPHONE_61"),
            "APP_IPHONE_61"
        ));
        assert!(screenshot_display_type_matches(
            Some("APP_DESKTOP"),
            "DESKTOP"
        ));
        assert!(!screenshot_display_type_matches(
            Some("APP_IPHONE_61"),
            "IPAD_PRO_3GEN_129"
        ));
    }

    #[test]
    fn media_ids_with_attribute_accepts_fallback_attribute_names() {
        let media = vec![json!(
            {
                "type": "appPreviews",
                "id": "preview-1",
                "attributes": { "appPreviewType": "DESKTOP" }
            }
        )];

        assert_eq!(
            media_ids_with_attribute(
                &media,
                "appPreviews",
                &["previewType", "appPreviewType"],
                "DESKTOP"
            ),
            vec!["preview-1".to_string()]
        );
    }
}
