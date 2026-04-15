//! Apple host-tool wrappers: PlistBuddy, codesign, security.
//!
//! Keeps argument assembly and output policy in one place so subcommands
//! don't reinvent invocation conventions.

use anyhow::Result;
use camino::Utf8Path;

use crate::output::Reporter;
use crate::process::Runner;

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

pub fn codesign_verify(reporter: &Reporter, bundle: &Utf8Path) -> Result<()> {
    Runner::new(reporter, "codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(bundle.as_std_path())
        .run()
}
