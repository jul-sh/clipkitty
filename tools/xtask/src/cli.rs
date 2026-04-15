use camino::Utf8PathBuf;
use clap::{Args, Parser, Subcommand, ValueEnum};

use crate::model::{AscAuthField, ReleaseChannel};

#[derive(Parser, Debug)]
#[command(
    name = "clipkitty",
    version,
    about = "ClipKitty automation CLI — one entrypoint for repo-owned automation",
    long_about = "All supported repo-owned automation runs through this binary. Host tools (xcodebuild, codesign, nix, age, asc, ...) stay at the edge; orchestration, validation, and policy live here."
)]
pub struct Cli {
    /// Print the exact host commands being executed.
    #[arg(long, short, global = true)]
    pub verbose: bool,

    /// Resolve inputs and print the plan without touching the filesystem or
    /// invoking host tools that mutate state.
    #[arg(long, global = true)]
    pub dry_run: bool,

    #[command(subcommand)]
    pub command: TopLevel,
}

#[derive(Subcommand, Debug)]
pub enum TopLevel {
    /// Verify repository automation invariants.
    Check,

    /// Install local helpers.
    #[command(subcommand)]
    Env(EnvCmd),

    /// Materialize the generated Xcode workspace/project.
    Workspace,

    /// Stage one supported macOS app artifact.
    App(AppArgs),

    /// Release packaging and publishing orchestration.
    #[command(subcommand)]
    Release(ReleaseCmd),

    /// Marketing asset generation.
    #[command(subcommand)]
    Marketing(MarketingCmd),

    /// Run the supported performance trace flow.
    Perf(PerfArgs),

    /// Resolve App Store Connect auth fields from repo secrets.
    #[command(subcommand)]
    Secrets(SecretsCmd),

    /// Public site assets.
    #[command(subcommand)]
    Site(SiteCmd),

    /// Hidden internal entrypoints used by repo-generated helpers.
    #[command(name = "__internal", hide = true, subcommand)]
    Internal(InternalCmd),
}

#[derive(Subcommand, Debug)]
pub enum EnvCmd {
    /// Install one local helper owned by the repo.
    Install(InstallArgs),
}

#[derive(Args, Debug)]
pub struct InstallArgs {
    #[arg(value_enum)]
    pub target: InstallTarget,
}

#[derive(ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallTarget {
    #[value(name = "hooks")]
    Hooks,
    #[value(name = "sparkle-cli")]
    SparkleCli,
}

#[derive(Subcommand, Debug)]
pub enum InternalCmd {
    /// Internal pre-commit entrypoint used by the generated git hook.
    PreCommit(PreCommitArgs),
}

#[derive(Args, Debug)]
pub struct PreCommitArgs {}

#[derive(Args, Debug)]
pub struct AppArgs {
    #[arg(value_enum)]
    pub target: AppTarget,
}

#[derive(ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppTarget {
    #[value(name = "hardened")]
    Hardened,
    #[value(name = "app-store")]
    AppStore,
}

#[derive(Subcommand, Debug)]
pub enum ReleaseCmd {
    /// Build, sign, and upload the macOS App Store variant.
    MacosAppstore(ReleaseMacArgs),
    /// Materialize, archive, export, and upload the iOS App Store variant.
    IosAppstore(ReleaseMacArgs),
    /// Build a signed Sparkle app and package it into a DMG.
    Dmg(DmgArgs),
    /// Appcast generation and state update (Sparkle).
    #[command(subcommand)]
    Appcast(AppcastCmd),
}

#[derive(Args, Debug)]
pub struct ReleaseMacArgs {
    /// Marketing version (CFBundleShortVersionString).
    pub version: String,
    /// Build number (CFBundleVersion).
    pub build_number: String,
}

#[derive(Args, Debug)]
pub struct DmgArgs {}

#[derive(Subcommand, Debug)]
pub enum AppcastCmd {
    /// Render appcast.xml from state JSON.
    Generate(AppcastGenerateArgs),
    /// Mutate the release state JSON atomically.
    UpdateState(AppcastUpdateStateArgs),
}

#[derive(Args, Debug)]
pub struct AppcastGenerateArgs {
    #[arg(long)]
    pub state_path: Utf8PathBuf,
    #[arg(long)]
    pub output_path: Utf8PathBuf,
}

#[derive(Args, Debug)]
pub struct AppcastUpdateStateArgs {
    #[arg(long)]
    pub state_path: Utf8PathBuf,
    #[arg(long, value_enum)]
    pub channel: ReleaseChannel,
    #[arg(long)]
    pub version: String,
    #[arg(long)]
    pub url: String,
    #[arg(long)]
    pub signature: String,
    #[arg(long)]
    pub length: u64,
}

#[derive(Subcommand, Debug)]
pub enum MarketingCmd {
    /// Capture localized screenshots for one platform.
    Screenshots(ScreenshotsArgs),
    /// Record localized intro videos.
    IntroVideo,
}

#[derive(Args, Debug)]
pub struct ScreenshotsArgs {
    #[arg(value_enum)]
    pub platform: ScreenshotPlatform,
}

#[derive(ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenshotPlatform {
    #[value(name = "macos")]
    MacOs,
    #[value(name = "ios")]
    Ios,
}

#[derive(Args, Debug)]
pub struct PerfArgs {
    #[arg(long, default_value_t = 250)]
    pub hang_threshold: u64,
    #[arg(long)]
    pub fail_on_hangs: bool,
}

#[derive(Subcommand, Debug)]
pub enum SecretsCmd {
    /// Print the resolved ASC auth field (key-id | issuer-id | private-key-b64).
    AscAuth(AscAuthArgs),
}

#[derive(Args, Debug)]
pub struct AscAuthArgs {
    #[arg(value_enum)]
    pub field: AscAuthField,
}

#[derive(Subcommand, Debug)]
pub enum SiteCmd {
    /// Render one public site asset.
    Render(SiteRenderArgs),
}

#[derive(Args, Debug)]
pub struct SiteRenderArgs {
    #[arg(value_enum)]
    pub target: SiteRenderTarget,
}

#[derive(ValueEnum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum SiteRenderTarget {
    #[value(name = "icon")]
    Icon,
    #[value(name = "landing-page")]
    LandingPage,
}
