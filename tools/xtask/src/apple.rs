//! Apple host-tool wrappers: PlistBuddy, codesign, security.
//!
//! Keeps argument assembly and output policy in one place so subcommands
//! don't reinvent invocation conventions.

use std::fs;

use anyhow::{anyhow, Result};
use camino::{Utf8Path, Utf8PathBuf};

use crate::output::Reporter;
use crate::process::Runner;

/// Duo's edge-to-edge layout requires linking against the iOS 27.1 SDK.
/// This does not change the app's iOS 26 deployment target.
pub fn require_ios_sdk(reporter: &Reporter) -> Result<()> {
    let output = Runner::new(reporter, "xcrun")
        .args(["--sdk", "iphoneos", "--show-sdk-version"])
        .sanitize_for_xcode()
        .output()?;
    validate_ios_sdk_version(output.stdout_string()?.trim())
}

fn validate_ios_sdk_version(version: &str) -> Result<()> {
    let components = version
        .split('.')
        .map(str::parse::<u32>)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| anyhow!("unrecognized iOS SDK version `{version}`"))?;
    let major = components[0];
    let minor = components.get(1).copied().unwrap_or(0);
    if (major, minor) < (27, 1) {
        return Err(anyhow!(
            "iOS builds require the iOS 27.1 SDK or later (Xcode 27.1+) for iPhone Duo support; found {version}"
        ));
    }
    Ok(())
}

pub fn plist_set(reporter: &Reporter, plist: &Utf8Path, key: &str, value: &str) -> Result<()> {
    Runner::new(reporter, "/usr/libexec/PlistBuddy")
        .arg("-c")
        .arg(format!("Set :{key} {value}"))
        .arg(plist.as_std_path())
        .run()
}

pub fn codesign_available(reporter: &Reporter, identity: &str) -> Result<bool> {
    let out = Runner::new(reporter, "security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .output()?;
    let text = out.stdout_string()?;
    Ok(text.contains(identity))
}

pub struct CodesignArgs<'a> {
    pub identity: &'a str,
    pub entitlements: &'a Utf8Path,
    pub include_timestamp: bool,
    pub bundle: &'a Utf8Path,
}

pub fn codesign(reporter: &Reporter, args: CodesignArgs<'_>) -> Result<()> {
    // The Nix build produces unsigned bundles (CODE_SIGNING_ALLOWED=NO), so
    // any embedded frameworks (e.g. SparkleUpdater.framework) must be signed
    // before the outer bundle — codesign refuses to sign a container whose
    // subcomponents aren't signed.
    for nested in nested_bundles_to_sign(args.bundle)? {
        codesign_nested(reporter, args.identity, args.include_timestamp, &nested)?;
    }
    let mut runner = Runner::new(reporter, "codesign").args(["--force", "--options", "runtime"]);
    if args.include_timestamp {
        runner = runner.arg("--timestamp");
    }
    runner
        .arg("--sign")
        .arg(args.identity)
        .arg("--entitlements")
        .arg(args.entitlements.as_std_path())
        .arg(args.bundle.as_std_path())
        .run()
}

fn nested_bundles_to_sign(bundle: &Utf8Path) -> Result<Vec<Utf8PathBuf>> {
    let frameworks_dir = bundle.join("Contents/Frameworks");
    if !frameworks_dir.as_std_path().is_dir() {
        return Ok(Vec::new());
    }
    let mut nested = Vec::new();
    for entry in fs::read_dir(frameworks_dir.as_std_path())
        .map_err(|err| anyhow!("reading {frameworks_dir}: {err}"))?
    {
        let entry = entry.map_err(|err| anyhow!("reading {frameworks_dir}: {err}"))?;
        let path = Utf8PathBuf::from_path_buf(entry.path())
            .map_err(|p| anyhow!("non-UTF-8 path under {frameworks_dir}: {}", p.display()))?;
        let Some(ext) = path.extension() else {
            continue;
        };
        if matches!(ext, "framework" | "dylib") {
            nested.push(path);
        }
    }
    nested.sort();
    Ok(nested)
}

fn codesign_nested(
    reporter: &Reporter,
    identity: &str,
    include_timestamp: bool,
    bundle: &Utf8Path,
) -> Result<()> {
    // `--deep` is safe here because nested bundles don't carry their own
    // entitlements — we only want to apply the .app's entitlements to the
    // outer bundle. Using --deep recursively signs helpers like
    // Sparkle.framework/Versions/B/Autoupdate and Updater.app.
    let mut runner =
        Runner::new(reporter, "codesign").args(["--force", "--deep", "--options", "runtime"]);
    if include_timestamp {
        runner = runner.arg("--timestamp");
    }
    runner
        .arg("--sign")
        .arg(identity)
        .arg(bundle.as_std_path())
        .run()
}

pub fn codesign_verify(reporter: &Reporter, bundle: &Utf8Path) -> Result<()> {
    Runner::new(reporter, "codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(bundle.as_std_path())
        .run()
}

#[cfg(test)]
mod tests {
    use super::validate_ios_sdk_version;

    #[test]
    fn ios_sdk_floor_accepts_patch_and_future_versions() {
        for version in ["27.1", "27.1.0", "27.1.2", "27.10", "28", "28.0"] {
            assert!(validate_ios_sdk_version(version).is_ok(), "{version}");
        }
    }

    #[test]
    fn ios_sdk_floor_rejects_older_and_malformed_versions() {
        for version in [
            "26.5", "27", "27.0", "27.0.99", "", "27.1beta", "27..1", "27.1.bad",
        ] {
            assert!(validate_ios_sdk_version(version).is_err(), "{version}");
        }
    }
}
