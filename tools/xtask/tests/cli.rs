//! Lock the public CLI surface.

use clap::Parser;
use xtask::cli::{
    AppArgs, AppTarget, AppcastCmd, Cli, EnvCmd, InstallTarget, MarketingCmd, ReleaseCmd,
    ScreenshotPlatform, SecretsCmd, SiteCmd, SiteRenderTarget, TopLevel,
};
use xtask::model::{AscAuthField, ReleaseChannel};

#[test]
fn parses_check() {
    let cli = Cli::parse_from(["clipkitty", "check"]);
    assert!(matches!(cli.command, TopLevel::Check));
}

#[test]
fn parses_workspace() {
    let cli = Cli::parse_from(["clipkitty", "workspace"]);
    assert!(matches!(cli.command, TopLevel::Workspace));
}

#[test]
fn parses_app_targets() {
    for (input, expected) in [
        ("hardened", AppTarget::Hardened),
        ("app-store", AppTarget::AppStore),
    ] {
        let cli = Cli::parse_from(["clipkitty", "app", input]);
        let TopLevel::App(AppArgs { target }) = cli.command else {
            panic!("expected app target");
        };
        assert_eq!(target, expected, "input={input}");
    }
}

#[test]
fn parses_env_install_targets() {
    for (input, expected) in [
        ("hooks", InstallTarget::Hooks),
        ("sparkle-cli", InstallTarget::SparkleCli),
    ] {
        let cli = Cli::parse_from(["clipkitty", "env", "install", input]);
        let TopLevel::Env(EnvCmd::Install(args)) = cli.command else {
            panic!("expected env install");
        };
        assert_eq!(args.target, expected, "input={input}");
    }
}

#[test]
fn parses_release_macos_appstore() {
    let cli = Cli::parse_from(["clipkitty", "release", "macos-appstore", "1.2.3", "42"]);
    let TopLevel::Release(ReleaseCmd::MacosAppstore(args)) = cli.command else {
        panic!("expected release macos-appstore");
    };
    assert_eq!(args.version, "1.2.3");
    assert_eq!(args.build_number, "42");
}

#[test]
fn parses_release_dmg() {
    let cli = Cli::parse_from(["clipkitty", "release", "dmg"]);
    let TopLevel::Release(ReleaseCmd::Dmg(_args)) = cli.command else {
        panic!("expected release dmg");
    };
}

#[test]
fn parses_release_appcast_update_state() {
    let cli = Cli::parse_from([
        "clipkitty",
        "release",
        "appcast",
        "update-state",
        "--state-path",
        "/tmp/state.json",
        "--channel",
        "beta",
        "--version",
        "1.0",
        "--url",
        "https://example.com/app.dmg",
        "--signature",
        "sig",
        "--length",
        "1234",
    ]);
    let TopLevel::Release(ReleaseCmd::Appcast(AppcastCmd::UpdateState(args))) = cli.command else {
        panic!("expected release appcast update-state");
    };
    assert_eq!(args.channel, ReleaseChannel::Beta);
    assert_eq!(args.length, 1234);
}

#[test]
fn parses_marketing_commands() {
    let mac = Cli::parse_from(["clipkitty", "marketing", "screenshots", "macos"]);
    let TopLevel::Marketing(MarketingCmd::Screenshots(args)) = mac.command else {
        panic!("expected marketing screenshots");
    };
    assert_eq!(args.platform, ScreenshotPlatform::MacOs);

    let ios = Cli::parse_from(["clipkitty", "marketing", "screenshots", "ios"]);
    let TopLevel::Marketing(MarketingCmd::Screenshots(args)) = ios.command else {
        panic!("expected marketing screenshots");
    };
    assert_eq!(args.platform, ScreenshotPlatform::Ios);

    let intro = Cli::parse_from(["clipkitty", "marketing", "intro-video"]);
    assert!(matches!(
        intro.command,
        TopLevel::Marketing(MarketingCmd::IntroVideo)
    ));
}

#[test]
fn parses_perf() {
    let cli = Cli::parse_from([
        "clipkitty",
        "perf",
        "--hang-threshold",
        "250",
        "--fail-on-hangs",
    ]);
    let TopLevel::Perf(args) = cli.command else {
        panic!("expected perf");
    };
    assert_eq!(args.hang_threshold, 250);
    assert!(args.fail_on_hangs);
}

#[test]
fn parses_secrets_asc_auth() {
    for (input, expected) in [
        ("key-id", AscAuthField::KeyId),
        ("issuer-id", AscAuthField::IssuerId),
        ("private-key-b64", AscAuthField::PrivateKeyB64),
    ] {
        let cli = Cli::parse_from(["clipkitty", "secrets", "asc-auth", input]);
        let TopLevel::Secrets(SecretsCmd::AscAuth(args)) = cli.command else {
            panic!("expected secrets asc-auth");
        };
        assert_eq!(args.field, expected);
    }
}

#[test]
fn parses_site_render() {
    let icon = Cli::parse_from(["clipkitty", "site", "render", "icon"]);
    let TopLevel::Site(SiteCmd::Render(args)) = icon.command else {
        panic!("expected site render");
    };
    assert_eq!(args.target, SiteRenderTarget::Icon);

    let landing = Cli::parse_from(["clipkitty", "site", "render", "landing-page"]);
    let TopLevel::Site(SiteCmd::Render(args)) = landing.command else {
        panic!("expected site render");
    };
    assert_eq!(args.target, SiteRenderTarget::LandingPage);
}

#[test]
fn verbose_and_dry_run_flags_propagate() {
    let cli = Cli::parse_from(["clipkitty", "--verbose", "--dry-run", "check"]);
    assert!(cli.verbose);
    assert!(cli.dry_run);
}

#[test]
fn rejects_internalized_legacy_commands() {
    for argv in [
        ["clipkitty", "check", "pins"].as_slice(),
        ["clipkitty", "build", "generate"].as_slice(),
        ["clipkitty", "build", "app", "Release"].as_slice(),
        ["clipkitty", "sign", "app", "Hardened"].as_slice(),
        ["clipkitty", "app", "release"].as_slice(),
        ["clipkitty", "env", "install-hooks"].as_slice(),
        ["clipkitty", "env", "install-sparkle-cli"].as_slice(),
        ["clipkitty", "marketing", "screenshots-macos"].as_slice(),
        ["clipkitty", "marketing", "patch-demo-items"].as_slice(),
        ["clipkitty", "perf", "run", "typing"].as_slice(),
        ["clipkitty", "perf", "--output", "perf_traces"].as_slice(),
        ["clipkitty", "site", "icon"].as_slice(),
        [
            "clipkitty",
            "release",
            "macos-appstore",
            "1.2.3",
            "42",
            "--metadata-only",
        ]
        .as_slice(),
        ["clipkitty", "release", "dmg", "--output", "ClipKitty.dmg"].as_slice(),
    ] {
        assert!(Cli::try_parse_from(argv).is_err(), "argv={argv:?}");
    }
}
