//! Lock the public CLI surface.

use clap::Parser;
use xtask::cli::{
    AppArgs, AppTarget, AppcastCmd, Cli, MarketingCmd, ReleaseCmd, ScreenshotPlatform, TopLevel,
};
use xtask::model::ReleaseChannel;

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
fn verbose_and_dry_run_flags_propagate() {
    let cli = Cli::parse_from(["clipkitty", "--verbose", "--dry-run", "app", "hardened"]);
    assert!(cli.verbose);
    assert!(cli.dry_run);
}

#[test]
fn rejects_commands_now_owned_by_make() {
    for argv in [
        ["clipkitty", "check"].as_slice(),
        ["clipkitty", "workspace"].as_slice(),
        ["clipkitty", "env", "install", "hooks"].as_slice(),
        ["clipkitty", "env", "install", "sparkle-cli"].as_slice(),
        ["clipkitty", "secrets", "asc-auth", "key-id"].as_slice(),
        ["clipkitty", "site", "render", "icon"].as_slice(),
        ["clipkitty", "site", "render", "landing-page"].as_slice(),
        ["clipkitty", "release", "version", "version"].as_slice(),
    ] {
        assert!(Cli::try_parse_from(argv).is_err(), "argv={argv:?}");
    }
}
