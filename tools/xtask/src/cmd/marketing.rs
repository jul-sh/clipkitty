//! `clipkitty marketing` — screenshot, intro-video, and demo-data orchestration.
//!
//! The old shell/Python helpers are now first-class Rust commands. Apple
//! tooling still lives at the edge (`xcodebuild`, `osascript`, `xcresulttool`,
//! `ffmpeg`), but sequencing, locale selection, DB preparation, and file
//! layout are all owned here.

use std::collections::{hash_map::DefaultHasher, BTreeMap};
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::thread;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};
use chrono::{Duration as ChronoDuration, Local, NaiveDateTime};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use uuid::Uuid;

use crate::cli::{MarketingCmd, ScreenshotPlatform};
use crate::cmd::build;
use crate::cmd::sign;
use crate::model::SetupAction;
use crate::model::SideEffectLevel;
use crate::output::Reporter;
use crate::process::Runner;
use crate::repo::RepoRoot;

const SCREENSHOT_LOCALE_FILE: &str = "/tmp/clipkitty_screenshot_locale.txt";
const SCREENSHOT_DB_FILE: &str = "/tmp/clipkitty_screenshot_db.txt";
const IOS_SCREENSHOT_LOCALE_FILE: &str = "/tmp/clipkitty_ios_screenshot_locale.txt";
const IOS_SCREENSHOT_DB_FILE: &str = "/tmp/clipkitty_ios_screenshot_db.txt";
const VIDEO_RESULT_BUNDLE: &str = "/tmp/clipkitty_video_result.xcresult";
const VIDEO_ATTACHMENTS_DIR: &str = "/tmp/xcresult-attachments";
const VIDEO_BOUNDS_FILE: &str = "/tmp/clipkitty_window_bounds.txt";
const VIDEO_OFFSET_FILE: &str = "/tmp/clipkitty_video_start_offset.txt";
const VIDEO_TYPING_LATENCY_FILE: &str = "/tmp/clipkitty_video_typing_latency.json";
const SILVER_BACKGROUND: &str = "/System/Library/Desktop Pictures/Solid Colors/Silver.png";

pub fn run(cmd: &MarketingCmd, dry_run: bool, reporter: &Reporter) -> Result<()> {
    let _ = SideEffectLevel::LocalMutation;
    let repo = RepoRoot::discover(reporter)?;
    match cmd {
        MarketingCmd::Screenshots(args) => match args.platform {
            ScreenshotPlatform::MacOs => screenshots_macos(&repo, dry_run, reporter),
            ScreenshotPlatform::Ios => screenshots_ios(&repo, dry_run, reporter),
        },
        MarketingCmd::IntroVideo => intro_video(&repo, dry_run, reporter),
    }
}

/// The fixed set of locales the marketing pipeline supports. Anything else
/// would break downstream screenshot mapping, so we model them explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MarketingLocale {
    En,
    Es,
    ZhHans,
    ZhHant,
    Ja,
    Ko,
    Fr,
    De,
    PtBr,
    Ru,
}

impl MarketingLocale {
    const ALL: [Self; 10] = [
        Self::En,
        Self::Es,
        Self::ZhHans,
        Self::ZhHant,
        Self::Ja,
        Self::Ko,
        Self::Fr,
        Self::De,
        Self::PtBr,
        Self::Ru,
    ];

    fn as_code(self) -> &'static str {
        match self {
            Self::En => "en",
            Self::Es => "es",
            Self::ZhHans => "zh-Hans",
            Self::ZhHant => "zh-Hant",
            Self::Ja => "ja",
            Self::Ko => "ko",
            Self::Fr => "fr",
            Self::De => "de",
            Self::PtBr => "pt-BR",
            Self::Ru => "ru",
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum CapturePlatform {
    MacOs,
    Ios,
}

#[derive(Debug, Clone, Copy)]
enum ScreenshotDbMode {
    LocalizedDatabases,
    SharedEnglishDatabase,
}

#[derive(Debug, Clone, Copy)]
enum MissingScreenshotPolicy {
    Fail,
    Warn,
}

#[derive(Debug, Clone, Copy)]
struct ScreenshotPlan {
    platform: CapturePlatform,
    locale_file: &'static str,
    db_file: &'static str,
    marketing_root: &'static str,
    scheme: &'static str,
    destination: &'static str,
    derived_data: &'static str,
    only_testing: &'static str,
    db_mode: ScreenshotDbMode,
    missing_policy: MissingScreenshotPolicy,
    prepare_macos_environment: bool,
}

impl ScreenshotPlan {
    fn macos() -> Self {
        Self {
            platform: CapturePlatform::MacOs,
            locale_file: SCREENSHOT_LOCALE_FILE,
            db_file: SCREENSHOT_DB_FILE,
            marketing_root: "marketing",
            scheme: "ClipKittyUITests",
            destination: "platform=macOS",
            derived_data: "DerivedData-marketing",
            only_testing: "ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots",
            db_mode: ScreenshotDbMode::LocalizedDatabases,
            missing_policy: MissingScreenshotPolicy::Fail,
            prepare_macos_environment: true,
        }
    }

    fn ios() -> Self {
        Self {
            platform: CapturePlatform::Ios,
            locale_file: IOS_SCREENSHOT_LOCALE_FILE,
            db_file: IOS_SCREENSHOT_DB_FILE,
            marketing_root: "marketing-ios",
            scheme: "ClipKittyiOSUITests",
            destination: "platform=iOS Simulator,name=iPhone 17",
            derived_data: "DerivedData",
            only_testing:
                "ClipKittyiOSUITests/ClipKittyiOSScreenshotTests/testTakeMarketingScreenshots",
            db_mode: ScreenshotDbMode::LocalizedDatabases,
            missing_policy: MissingScreenshotPolicy::Fail,
            prepare_macos_environment: false,
        }
    }
}

fn screenshots_macos(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    run_screenshot_plan(repo, ScreenshotPlan::macos(), dry_run, reporter)
}

fn screenshots_ios(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    run_screenshot_plan(repo, ScreenshotPlan::ios(), dry_run, reporter)
}

fn run_screenshot_plan(
    repo: &RepoRoot,
    plan: ScreenshotPlan,
    dry_run: bool,
    reporter: &Reporter,
) -> Result<()> {
    if dry_run {
        reporter.info(&format!(
            "[dry-run] would capture {:?} marketing screenshots into {}",
            plan.platform, plan.marketing_root
        ));
        if matches!(plan.db_mode, ScreenshotDbMode::LocalizedDatabases) {
            reporter.info("[dry-run] would refresh localized demo databases first");
        }
        return Ok(());
    }

    build::generate(repo, false, reporter)?;

    if matches!(plan.db_mode, ScreenshotDbMode::LocalizedDatabases) {
        patch_demo_items(repo, false, reporter)?;
    }

    let temp_files = TempSelectionFiles::new(&[
        Utf8PathBuf::from(plan.locale_file),
        Utf8PathBuf::from(plan.db_file),
    ]);

    for locale in MarketingLocale::ALL {
        let locale_code = locale.as_code();
        reporter.info(&format!(
            "Capturing {:?} screenshots for {locale_code}...",
            plan.platform
        ));

        fs::create_dir_all(
            repo.join(format!("{}/{}", plan.marketing_root, locale_code))
                .as_std_path(),
        )
        .with_context(|| format!("creating {}/{}", plan.marketing_root, locale_code))?;

        fs::write(plan.locale_file, format!("{locale_code}\n"))
            .with_context(|| format!("writing {}", plan.locale_file))?;
        fs::write(
            plan.db_file,
            format!("{}\n", screenshot_db_name(locale, plan.db_mode)),
        )
        .with_context(|| format!("writing {}", plan.db_file))?;

        let _environment = if plan.prepare_macos_environment {
            Some(ScreenshotEnvironment::prepare(reporter)?)
        } else {
            None
        };

        let log_path = match plan.platform {
            CapturePlatform::MacOs => Utf8PathBuf::from(format!(
                "/tmp/clipkitty_marketing_xcodebuild_{locale_code}.log"
            )),
            CapturePlatform::Ios => Utf8PathBuf::from("/tmp/clipkitty_ios_screenshot_test.log"),
        };
        let status = run_screenshot_xcodebuild(repo, plan, &log_path, reporter)?;
        let copied = copy_screenshots(repo, plan, locale, reporter)?;
        if !copied {
            let log_tail = fs::read_to_string(log_path.as_std_path())
                .unwrap_or_else(|err| format!("(failed to read {log_path}: {err})"));
            reporter.info(&format!(
                "--- xcodebuild log for {locale_code} (exit {status}) ---\n{log_tail}\n--- end log ---"
            ));
            match plan.missing_policy {
                MissingScreenshotPolicy::Fail => {
                    return Err(anyhow!(
                        "no screenshots produced for {locale_code}; inspect {log_path}"
                    ));
                }
                MissingScreenshotPolicy::Warn => {
                    reporter.info(&format!(
                        "Warning: no screenshots produced for {locale_code}; inspect {log_path}"
                    ));
                }
            }
        } else if !status.success() {
            reporter.info(&format!(
                "Warning: xcodebuild exited with {status} for {locale_code}, but screenshots were captured"
            ));
        }
    }

    drop(temp_files);
    reporter.success(&format!(
        "Localized {:?} screenshots complete.",
        plan.platform
    ));
    Ok(())
}

fn screenshot_db_name(locale: MarketingLocale, mode: ScreenshotDbMode) -> String {
    match mode {
        ScreenshotDbMode::LocalizedDatabases => {
            if locale == MarketingLocale::En {
                "SyntheticData.sqlite".to_string()
            } else {
                format!("SyntheticData_{}.sqlite", locale.as_code())
            }
        }
        ScreenshotDbMode::SharedEnglishDatabase => "SyntheticData.sqlite".to_string(),
    }
}

fn run_screenshot_xcodebuild(
    repo: &RepoRoot,
    plan: ScreenshotPlan,
    log_path: &Utf8Path,
    reporter: &Reporter,
) -> Result<std::process::ExitStatus> {
    let workspace = repo.join("ClipKitty.xcworkspace");
    let mut runner = Runner::new(reporter, "xcodebuild")
        .args(["test", "-workspace"])
        .arg(workspace.as_std_path())
        .arg("-scheme")
        .arg(plan.scheme)
        .arg("-destination")
        .arg(plan.destination)
        .arg("-derivedDataPath")
        .arg(repo.join(plan.derived_data).as_std_path())
        .arg("-only-testing")
        .arg(plan.only_testing)
        .cwd(repo.as_path())
        .sanitize_for_xcode()
        // build::generate already staged libpurr.a; skip the Xcode
        // pre-build action so it doesn't try to rebuild Rust inside the
        // sanitised (nix-free) xcodebuild environment.
        .env("CLIPKITTY_SKIP_RUST_PREBUILD", "1")
        .capture_stdout()
        .capture_stderr();
    if matches!(plan.platform, CapturePlatform::Ios)
        || env::var("SKIP_SIGNING").ok().as_deref() == Some("1")
    {
        runner = runner.arg("CODE_SIGNING_ALLOWED=NO");
    }

    let output = runner.output_status()?;
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    fs::write(log_path.as_std_path(), combined.as_bytes())
        .with_context(|| format!("writing {log_path}"))?;
    for line in combined.lines() {
        if line.contains("Test Case") || line.contains("passed") || line.contains("failed") {
            reporter.info(line);
        }
    }
    Ok(output.status)
}

fn copy_screenshots(
    repo: &RepoRoot,
    plan: ScreenshotPlan,
    locale: MarketingLocale,
    reporter: &Reporter,
) -> Result<bool> {
    let locale_code = locale.as_code();
    let prefix = match (plan.platform, locale) {
        (CapturePlatform::MacOs, MarketingLocale::En) => "/tmp/clipkitty_marketing".to_string(),
        (CapturePlatform::MacOs, _) => format!("/tmp/clipkitty_{locale_code}_marketing"),
        (CapturePlatform::Ios, MarketingLocale::En) => "/tmp/clipkitty_ios_marketing".to_string(),
        (CapturePlatform::Ios, _) => format!("/tmp/clipkitty_ios_{locale_code}_marketing"),
    };
    let target_dir = repo.join(format!("{}/{}", plan.marketing_root, locale_code));
    let mut copied = 0usize;

    for (index, suffix) in [(1, "history"), (2, "search"), (3, "filter")] {
        let source = Utf8PathBuf::from(format!("{prefix}_{index}_{suffix}.png"));
        let target = target_dir.join(format!("screenshot_{index}.png"));
        if source.as_std_path().is_file() {
            fs::copy(source.as_std_path(), target.as_std_path())
                .with_context(|| format!("copying {source} to {target}"))?;
            copied += 1;
        }
    }

    if copied > 0 {
        reporter.info(&format!("  saved screenshots to {target_dir}"));
    }
    Ok(copied > 0)
}

fn intro_video(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    if dry_run {
        reporter.info("[dry-run] would record localized intro videos into marketing/<locale>/");
        reporter.info("[dry-run] would refresh localized demo databases first");
        return Ok(());
    }

    build::generate(repo, false, reporter)?;
    patch_demo_items(repo, false, reporter)?;
    let locale_file = Utf8PathBuf::from(SCREENSHOT_LOCALE_FILE);
    let _cleanup = TempSelectionFiles::new(&[locale_file.clone()]);

    for locale in MarketingLocale::ALL {
        let locale_code = locale.as_code();
        reporter.info(&format!("Recording intro video for {locale_code}..."));
        fs::write(locale_file.as_std_path(), format!("{locale_code}\n"))
            .with_context(|| format!("writing {locale_file}"))?;

        let video_db = repo.join("distribution/SyntheticData_video.sqlite");
        let source_db = repo.join(format!(
            "distribution/{}",
            screenshot_db_name(locale, ScreenshotDbMode::LocalizedDatabases)
        ));
        fs::copy(source_db.as_std_path(), video_db.as_std_path())
            .with_context(|| format!("copying {source_db} to {video_db}"))?;

        run_rust_data_gen(
            repo,
            &[
                "--video-only",
                "--locale",
                locale_code,
                "--db-path",
                "distribution/SyntheticData_video.sqlite",
            ],
            reporter,
        )?;
        inject_images_impl(repo, &video_db, locale, reporter)?;

        let _environment = ScreenshotEnvironment::prepare(reporter)?;
        record_preview_video(
            repo,
            "testRecordIntroVideo",
            "SyntheticData_video.sqlite",
            &repo.join(format!("marketing/{locale_code}/intro_video.mov")),
            30,
            reporter,
        )?;
        reporter.info(&format!("  saved marketing/{locale_code}/intro_video.mov"));
    }

    reporter.success("All localized intro videos complete.");
    Ok(())
}

fn patch_demo_items(repo: &RepoRoot, dry_run: bool, reporter: &Reporter) -> Result<()> {
    if dry_run {
        reporter.info("[dry-run] would refresh demo text items and inject localized images");
        return Ok(());
    }

    reporter.info("Patching synthetic data with demo items...");
    run_rust_data_gen(
        repo,
        &[
            "--demo-only",
            "--db-path",
            "distribution/SyntheticData.sqlite",
        ],
        reporter,
    )?;

    let base_db = repo.join("distribution/SyntheticData.sqlite");
    strip_images_from_database(&base_db)?;

    for locale in MarketingLocale::ALL {
        let locale_code = locale.as_code();
        let db_path = if locale == MarketingLocale::En {
            base_db.clone()
        } else {
            let path = repo.join(format!("distribution/SyntheticData_{locale_code}.sqlite"));
            fs::copy(base_db.as_std_path(), path.as_std_path())
                .with_context(|| format!("copying {base_db} to {path}"))?;
            run_rust_data_gen(
                repo,
                &[
                    "--demo-only",
                    "--locale",
                    locale_code,
                    "--db-path",
                    path.strip_prefix(repo.as_path())
                        .unwrap_or(path.as_path())
                        .as_str(),
                ],
                reporter,
            )?;
            path
        };
        inject_images_impl(repo, &db_path, locale, reporter)?;
    }

    reporter.success("Demo databases refreshed.");
    Ok(())
}

fn run_rust_data_gen(repo: &RepoRoot, args: &[&str], reporter: &Reporter) -> Result<()> {
    let locked = env::var("LOCKED").ok().as_deref() == Some("1");
    let mut runner = Runner::new(reporter, "cargo").arg("run");
    if locked {
        runner = runner.arg("--locked");
    }
    runner = runner.args(["-p", "rust-data-gen", "--release", "--"]);
    runner = runner.args(args.iter().copied());
    runner.cwd(repo.as_path()).run()
}

fn strip_images_from_database(db_path: &Utf8Path) -> Result<()> {
    let conn =
        Connection::open(db_path.as_std_path()).with_context(|| format!("opening {db_path}"))?;
    conn.execute_batch(
        "
        DELETE FROM image_items;
        DELETE FROM items WHERE contentType = 'image';
        VACUUM;
        ",
    )
    .with_context(|| format!("stripping image rows from {db_path}"))?;
    Ok(())
}

fn inject_images_impl(
    repo: &RepoRoot,
    db_path: &Utf8Path,
    locale: MarketingLocale,
    reporter: &Reporter,
) -> Result<()> {
    let images_dir = repo.join("distribution/images");
    let keywords_csv = repo.join("distribution/image_keywords.csv");
    let manifest_path = images_dir.join("manifest.json");
    if !db_path.as_std_path().is_file() {
        return Err(anyhow!("db not found: {db_path}"));
    }
    if !manifest_path.as_std_path().is_file() {
        return Err(anyhow!("manifest not found: {manifest_path}"));
    }

    let manifest: Vec<ManifestItem> = serde_json::from_slice(
        &fs::read(manifest_path.as_std_path())
            .with_context(|| format!("reading {manifest_path}"))?,
    )
    .with_context(|| format!("parsing {manifest_path}"))?;
    let keywords = load_locale_keywords(&keywords_csv, locale)?;

    let mut conn =
        Connection::open(db_path.as_std_path()).with_context(|| format!("opening {db_path}"))?;
    ensure_locale_column(&conn)?;

    let base_timestamp: NaiveDateTime = conn
        .query_row(
            "SELECT MAX(timestamp) FROM items WHERE contentType != 'image'",
            [],
            |row| row.get::<_, Option<String>>(0),
        )?
        .as_deref()
        .and_then(parse_db_timestamp)
        .unwrap_or_else(|| Local::now().naive_local());

    let tx = conn.transaction()?;
    let mut inserted = 0usize;
    for item in manifest {
        let asset = item.asset_for(locale);
        let image_path = images_dir.join(&asset.file);
        let thumb_path = images_dir.join(&asset.thumbnail);
        if !image_path.as_std_path().is_file() {
            reporter.info(&format!("Warning: image file missing: {image_path}"));
            continue;
        }

        let description = keywords
            .get(&item.description_en)
            .cloned()
            .unwrap_or_else(|| item.description_en.clone());
        let already_exists: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM image_items WHERE description = ?1 AND locale = ?2 LIMIT 1",
                params![description, locale.as_code()],
                |row| row.get(0),
            )
            .optional()?;
        if already_exists.is_some() {
            continue;
        }

        let image_data =
            fs::read(image_path.as_std_path()).with_context(|| format!("reading {image_path}"))?;
        let thumbnail = fs::read(thumb_path.as_std_path()).ok();
        let timestamp =
            base_timestamp + ChronoDuration::seconds(item.offset_seconds.unwrap_or(-3600));
        let timestamp = timestamp.format("%Y-%m-%d %H:%M:%S").to_string();
        let content_hash = stable_hash(&(description.as_str(), image_data.len(), locale.as_code()));
        let item_uuid = Uuid::new_v4().to_string();

        tx.execute(
            "INSERT INTO items (item_id, contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail)
             VALUES (?1, 'image', ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                item_uuid,
                content_hash,
                description,
                timestamp,
                item.source_app,
                item.bundle_id,
                thumbnail,
            ],
        )?;
        let item_id = tx.last_insert_rowid();
        tx.execute(
            "INSERT INTO image_items (itemId, data, description, locale) VALUES (?1, ?2, ?3, ?4)",
            params![item_id, image_data, description, locale.as_code()],
        )?;
        inserted += 1;
    }
    tx.commit()?;

    reporter.info(&format!(
        "Injected {inserted} images for locale `{}` into {db_path}",
        locale.as_code()
    ));
    Ok(())
}

#[derive(Debug, Deserialize)]
struct ManifestItem {
    file: String,
    thumbnail: String,
    description_en: String,
    source_app: String,
    bundle_id: String,
    offset_seconds: Option<i64>,
    #[serde(default)]
    locale_files: BTreeMap<String, LocaleAsset>,
}

#[derive(Debug, Deserialize, Clone)]
struct LocaleAsset {
    file: String,
    thumbnail: String,
}

impl ManifestItem {
    fn asset_for(&self, locale: MarketingLocale) -> LocaleAsset {
        self.locale_files
            .get(locale.as_code())
            .cloned()
            .unwrap_or_else(|| LocaleAsset {
                file: self.file.clone(),
                thumbnail: self.thumbnail.clone(),
            })
    }
}

fn load_locale_keywords(
    csv_path: &Utf8Path,
    locale: MarketingLocale,
) -> Result<BTreeMap<String, String>> {
    let mut reader = csv::Reader::from_path(csv_path.as_std_path())
        .with_context(|| format!("opening {csv_path}"))?;
    let column = locale_csv_column(locale);
    let mut out = BTreeMap::new();
    for row in reader.records() {
        let row = row?;
        if let (Some(en), Some(localized)) = (row.get(1), row.get(column)) {
            out.insert(en.to_string(), localized.to_string());
        }
    }
    Ok(out)
}

fn locale_csv_column(locale: MarketingLocale) -> usize {
    match locale {
        MarketingLocale::En => 1,
        MarketingLocale::Es => 2,
        MarketingLocale::Fr => 3,
        MarketingLocale::De => 4,
        MarketingLocale::Ja => 5,
        MarketingLocale::Ko => 6,
        MarketingLocale::ZhHans => 7,
        MarketingLocale::ZhHant => 8,
        MarketingLocale::PtBr => 9,
        MarketingLocale::Ru => 10,
    }
}

fn ensure_locale_column(conn: &Connection) -> Result<()> {
    let mut stmt = conn.prepare("PRAGMA table_info(image_items)")?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if !columns.iter().any(|column| column == "locale") {
        conn.execute(
            "ALTER TABLE image_items ADD COLUMN locale TEXT DEFAULT 'en'",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_image_locale ON image_items(locale)",
            [],
        )?;
    }
    Ok(())
}

fn parse_db_timestamp(raw: &str) -> Option<NaiveDateTime> {
    for format in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%d %H:%M:%S"] {
        if let Ok(timestamp) = NaiveDateTime::parse_from_str(raw, format) {
            return Some(timestamp);
        }
    }
    None
}

fn stable_hash(value: &impl Hash) -> String {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish().to_string()
}

fn record_preview_video(
    repo: &RepoRoot,
    test_name: &str,
    db_name: &str,
    output_path: &Utf8Path,
    max_duration: u64,
    reporter: &Reporter,
) -> Result<()> {
    if env::var("SKIP_SIGNING").ok().as_deref() != Some("1") {
        sign::setup(
            repo,
            &sign::SetupRequest {
                flow: sign::SetupFlow::Dev,
                action: SetupAction::Init,
            },
            false,
            reporter,
        )?;
    }

    let result_bundle = Utf8PathBuf::from(VIDEO_RESULT_BUNDLE);
    let attachments_dir = Utf8PathBuf::from(VIDEO_ATTACHMENTS_DIR);
    let db_file = Utf8PathBuf::from(SCREENSHOT_DB_FILE);

    close_clipkitty(reporter);
    remove_if_exists(&result_bundle)?;
    remove_if_exists(&attachments_dir)?;
    fs::create_dir_all(
        output_path
            .parent()
            .ok_or_else(|| anyhow!("output path has no parent: {output_path}"))?
            .as_std_path(),
    )?;
    fs::write(db_file.as_std_path(), format!("{db_name}\n"))
        .with_context(|| format!("writing {db_file}"))?;

    remove_if_exists(&repo.join("DerivedData/Build/Products/Debug/ClipKittyUITests-Runner.app"))?;
    let _ = Runner::new(reporter, "find")
        .arg(repo.join("DerivedData").as_std_path())
        .args(["-name", "*.cstemp", "-delete"])
        .status();

    let mut runner = Runner::new(reporter, "xcodebuild")
        .args(["test", "-workspace"])
        .arg(repo.join("ClipKitty.xcworkspace").as_std_path())
        .args([
            "-scheme",
            "ClipKittyUITests",
            "-testPlan",
            "ClipKittyVideoRecording",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
        ])
        .arg(repo.join("DerivedData").as_std_path())
        .arg("-resultBundlePath")
        .arg(result_bundle.as_std_path())
        .arg("-only-testing")
        .arg(format!("ClipKittyUITests/ClipKittyUITests/{test_name}"))
        .cwd(repo.as_path())
        .sanitize_for_xcode()
        // build::generate already staged libpurr.a; skip the Xcode
        // pre-build action so it doesn't try to rebuild Rust inside the
        // sanitised (nix-free) xcodebuild environment.
        .env("CLIPKITTY_SKIP_RUST_PREBUILD", "1")
        .capture_stdout()
        .capture_stderr();
    if env::var("SKIP_SIGNING").is_ok() {
        runner = runner.arg("CODE_SIGNING_ALLOWED=NO");
    }
    let output = runner.output_status()?;
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    for line in combined.lines() {
        if line.contains("Test Case") || line.contains("passed") || line.contains("failed") {
            reporter.info(line);
        }
    }
    fs::remove_file(db_file.as_std_path()).ok();

    if !result_bundle.as_std_path().is_dir() {
        return Err(anyhow!("xcresult bundle not found at {result_bundle}"));
    }

    fs::create_dir_all(attachments_dir.as_std_path())
        .with_context(|| format!("creating {attachments_dir}"))?;
    Runner::new(reporter, "xcrun")
        .args(["xcresulttool", "export", "attachments", "--path"])
        .arg(result_bundle.as_std_path())
        .arg("--output-path")
        .arg(attachments_dir.as_std_path())
        .run()?;

    let raw_video = find_video_attachment(&attachments_dir)?
        .ok_or_else(|| anyhow!("no screen recording video found in {attachments_dir}"))?;
    if tool_exists("ffmpeg") && tool_exists("ffprobe") {
        postprocess_video(&raw_video, output_path, max_duration, reporter)?;
    } else {
        fs::copy(raw_video.as_std_path(), output_path.as_std_path())
            .with_context(|| format!("copying {raw_video} to {output_path}"))?;
    }

    move_typing_latency_report(output_path, reporter);

    remove_if_exists(&attachments_dir)?;
    remove_if_exists(&result_bundle)?;
    close_clipkitty(reporter);
    Ok(())
}

/// If the UI test wrote a typing-latency report, move it next to the video
/// (`<video stem>_typing.json`) so it travels with the `.mov` as a CI artifact.
fn move_typing_latency_report(video_path: &Utf8Path, reporter: &Reporter) {
    let src = Utf8PathBuf::from(VIDEO_TYPING_LATENCY_FILE);
    if !src.as_std_path().exists() {
        return;
    }
    let stem = video_path.file_stem().unwrap_or("intro_video");
    let dest = match video_path.parent() {
        Some(parent) => parent.join(format!("{stem}_typing.json")),
        None => Utf8PathBuf::from(format!("{stem}_typing.json")),
    };
    match fs::rename(src.as_std_path(), dest.as_std_path()) {
        Ok(()) => reporter.info(&format!("  saved {dest}")),
        Err(err) => reporter.info(&format!(
            "  warn: could not move typing latency report to {dest}: {err}"
        )),
    }
}

fn postprocess_video(
    raw_video: &Utf8Path,
    output_path: &Utf8Path,
    max_duration: u64,
    reporter: &Reporter,
) -> Result<()> {
    let duration_output = Runner::new(reporter, "ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(raw_video.as_std_path())
        .output()?;
    let raw_duration = duration_output
        .stdout_string()?
        .trim()
        .parse::<f64>()
        .unwrap_or(0.0);
    let start_offset = fs::read_to_string(VIDEO_OFFSET_FILE)
        .ok()
        .and_then(|raw| raw.trim().parse::<f64>().ok())
        .unwrap_or(0.0);
    fs::remove_file(VIDEO_OFFSET_FILE).ok();

    let trim_duration = (raw_duration - start_offset)
        .max(0.0)
        .min(max_duration as f64)
        .min(30.0);
    let crop_filter = fs::read_to_string(VIDEO_BOUNDS_FILE)
        .ok()
        .and_then(|raw| {
            let parts = raw.trim().split(',').map(str::trim).collect::<Vec<_>>();
            if parts.len() == 4 {
                Some(format!(
                    "crop={}:{}:{}:{},",
                    parts[2], parts[3], parts[0], parts[1]
                ))
            } else {
                None
            }
        })
        .unwrap_or_default();
    fs::remove_file(VIDEO_BOUNDS_FILE).ok();

    // App Store Connect rejects previews without an audio track, so mux in silence.
    Runner::new(reporter, "ffmpeg")
        .args([
            "-y",
            "-ss",
        ])
        .arg(format!("{start_offset:.3}"))
        .arg("-i")
        .arg(raw_video.as_std_path())
        .args([
            "-f",
            "lavfi",
            "-i",
            "anullsrc=channel_layout=stereo:sample_rate=44100",
        ])
        .arg("-t")
        .arg(format!("{trim_duration:.3}"))
        .arg("-vf")
        .arg(format!(
            "{crop_filter}scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0xC0C0C0"
        ))
        .args([
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "18",
            "-profile:v",
            "high",
            "-level",
            "4.0",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-ar",
            "44100",
            "-ac",
            "2",
            "-shortest",
            "-movflags",
            "+faststart",
        ])
        .arg(output_path.as_std_path())
    .run()
}

fn close_clipkitty(reporter: &Reporter) {
    let _ = Runner::new(reporter, "osascript")
        .args(["-e", "quit app \"ClipKitty\""])
        .status();
    thread::sleep(Duration::from_secs(2));
}

fn find_video_attachment(dir: &Utf8Path) -> Result<Option<Utf8PathBuf>> {
    let mut videos = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(path.as_std_path()).with_context(|| format!("reading {path}"))? {
            let entry = entry?;
            let child = Utf8PathBuf::from_path_buf(entry.path())
                .map_err(|p| anyhow!("non-UTF-8 path: {p:?}"))?;
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                stack.push(child);
            } else if matches!(child.extension(), Some("mov") | Some("mp4")) {
                videos.push(child);
            }
        }
    }
    videos.sort();
    Ok(videos.into_iter().next())
}

struct TempSelectionFiles {
    paths: Vec<Utf8PathBuf>,
}

impl TempSelectionFiles {
    fn new(paths: &[Utf8PathBuf]) -> Self {
        Self {
            paths: paths.to_vec(),
        }
    }
}

impl Drop for TempSelectionFiles {
    fn drop(&mut self) {
        for path in &self.paths {
            let _ = fs::remove_file(path.as_std_path());
        }
    }
}

struct ScreenshotEnvironment<'a> {
    reporter: &'a Reporter,
    previous_desktop: Option<String>,
    visible_apps: Vec<String>,
}

impl<'a> ScreenshotEnvironment<'a> {
    fn prepare(reporter: &'a Reporter) -> Result<Self> {
        let previous_desktop = osascript_capture(
            reporter,
            "tell application \"Finder\" to get POSIX path of (desktop picture as alias)",
        )
        .ok()
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty());
        let visible_apps = osascript_capture(
            reporter,
            "tell application \"System Events\" to get name of every process whose visible is true",
        )
        .ok()
        .map(|text| {
            text.split(',')
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

        let _ = Runner::new(reporter, "osascript")
            .arg("-e")
            .arg(format!(
                "tell application \"Finder\" to set desktop picture to POSIX file \"{SILVER_BACKGROUND}\""
            ))
        .status();
        let _ = Runner::new(reporter, "osascript")
            .args([
            "-e",
            "tell application \"System Events\" to set visible of every process whose name is not \"ClipKitty\" to false",
            ])
        .status();
        // The app forces paste mode on under --use-simulated-db, so marketing
        // screenshots and intro videos always show "Paste" on the action
        // button regardless of accessibility permission state.
        if env::var_os("CI").is_some() {
            let _ = Runner::new(reporter, "defaults")
                .args(["write", "com.apple.dock", "persistent-apps", "-array"])
                .status();
            let _ = Runner::new(reporter, "killall").arg("Dock").status();
        }
        thread::sleep(Duration::from_secs(1));

        Ok(Self {
            reporter,
            previous_desktop,
            visible_apps,
        })
    }
}

impl Drop for ScreenshotEnvironment<'_> {
    fn drop(&mut self) {
        for app in &self.visible_apps {
            let _ = Runner::new(self.reporter, "osascript")
                .arg("-e")
                .arg(format!(
                    "tell application \"System Events\" to set visible of process \"{}\" to true",
                    app.replace('"', "\\\"")
                ))
                .status();
        }
        if let Some(previous_desktop) = &self.previous_desktop {
            if Utf8Path::new(previous_desktop).as_std_path().is_file() {
                let _ = Runner::new(self.reporter, "osascript")
                    .arg("-e")
                    .arg(format!(
                        "tell application \"Finder\" to set desktop picture to POSIX file \"{}\"",
                        previous_desktop.replace('"', "\\\"")
                    ))
                    .status();
            }
        }
    }
}

fn osascript_capture(reporter: &Reporter, script: &str) -> Result<String> {
    Runner::new(reporter, "osascript")
        .arg("-e")
        .arg(script)
        .output()?
        .stdout_string()
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

fn tool_exists(name: &str) -> bool {
    std::process::Command::new("which")
        .arg(name)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

