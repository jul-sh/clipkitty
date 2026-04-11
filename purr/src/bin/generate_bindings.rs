//! Generate UniFFI Swift bindings for ClipKitty
//!
//! Run: cargo run --bin generate-bindings
//!
//! ┌─────────────────────────────────────────────────────────────────────────────┐
//! │ DEPENDENCY MAP - Output paths must match the Bazel + Makefile bridge        │
//! │                                                                             │
//! │ Inputs:                                                                     │
//! │   target/release/libpurr.dylib       ← Built library for bindgen            │
//! │                                                                             │
//! │ Outputs (paths consumed by the Apple Bazel targets):                        │
//! │   Sources/ClipKittyRust/purrFFI.h             ← C header                    │
//! │   Sources/ClipKittyRust/module.modulemap      ← Clang module map            │
//! │   Sources/ClipKittyRust/libpurr.a             ← macOS universal static lib  │
//! │   Sources/ClipKittyRust/ios-device/libpurr.a  ← iOS device (aarch64)        │
//! │   Sources/ClipKittyRust/ios-simulator/libpurr.a ← iOS simulator (aarch64)   │
//! │   Sources/ClipKittyRustWrapper/purr.swift     ← Swift bindings              │
//! │                                                                             │
//! │ Manual file (not generated):                                                │
//! │   Sources/ClipKittyRustWrapper/ClipKittyRust.swift ← Swift extensions       │
//! └─────────────────────────────────────────────────────────────────────────────┘

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let rust_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let project_root = rust_dir.parent().expect("No parent directory");

    // Use CARGO_TARGET_DIR if set (shared across worktrees), else default.
    let target_dir = env::var("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| project_root.join("target"));

    // Keep the Rust artifacts aligned with the app's supported macOS floor.
    let deployment_target =
        env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "14.0".to_string());
    env::set_var("MACOSX_DEPLOYMENT_TARGET", &deployment_target);

    println!("Building Rust library...");
    run_cmd("cargo", &["build", "--release"], &rust_dir);

    let dylib_path = target_dir.join("release/libpurr.dylib");
    let generated_dir = rust_dir.join("generated");

    println!("Generating Swift bindings...");
    run_cmd(
        "cargo",
        &[
            "run",
            "--bin",
            "uniffi-bindgen",
            "generate",
            "--library",
            &dylib_path.to_string_lossy(),
            "--language",
            "swift",
            "--out-dir",
            &generated_dir.to_string_lossy(),
        ],
        &rust_dir,
    );

    let swift_dest = project_root.join("Sources/ClipKittyRust");
    let wrapper_dest = project_root.join("Sources/ClipKittyRustWrapper");
    let generated = generated_dir;

    // Read and fix Swift 6 concurrency + module import
    println!("Copying generated Swift file...");
    let mut swift_content =
        fs::read_to_string(generated.join("purr.swift")).expect("Read swift file");
    swift_content = swift_content.replace(
        "private var initializationResult",
        "nonisolated(unsafe) private var initializationResult",
    );
    swift_content =
        swift_content.replace("#if canImport(purrFFI)", "#if canImport(ClipKittyRustFFI)");
    swift_content = swift_content.replace("import purrFFI", "import ClipKittyRustFFI");
    fs::write(wrapper_dest.join("purr.swift"), swift_content).expect("Write swift");

    // Copy header
    fs::copy(generated.join("purrFFI.h"), swift_dest.join("purrFFI.h")).expect("Copy header");

    // Write modulemap
    println!("Writing modulemap...");
    fs::write(
        swift_dest.join("module.modulemap"),
        "module ClipKittyRustFFI {\n    header \"purrFFI.h\"\n    export *\n}\n",
    )
    .expect("Write modulemap");

    // Build static libraries.
    //
    // UNIVERSAL=1 (CI/release): macOS universal binary (aarch64 + x86_64 via lipo)
    // Without UNIVERSAL (dev): macOS host arch only (skips x86_64 build + lipo)
    // iOS device + simulator are always built.
    let universal = env::var("UNIVERSAL").map_or(false, |v| v == "1");

    println!("Building static libraries{}...", if universal { " (universal)" } else { "" });

    let output_lib = swift_dest.join("libpurr.a");

    // --- macOS ---
    if universal {
        let mac_targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"];
        let installed_targets = installed_rust_targets();
        for target in &mac_targets {
            assert!(
                installed_targets.iter().any(|t| t == target),
                "Required Rust target {target} is not installed. \
                 Run inside `nix develop` or add it to flake.nix targets."
            );
        }

        for target in &mac_targets {
            run_cmd("cargo", &["build", "--release", "--target", target], &rust_dir);
        }
        run_cmd(
            "lipo",
            &[
                "-create",
                &target_dir
                    .join("aarch64-apple-darwin/release/libpurr.a")
                    .to_string_lossy(),
                &target_dir
                    .join("x86_64-apple-darwin/release/libpurr.a")
                    .to_string_lossy(),
                "-output",
                &output_lib.to_string_lossy(),
            ],
            &rust_dir,
        );
        println!("Created universal macOS static library");
    } else {
        let host_target = env::consts::ARCH;
        let rust_target = match host_target {
            "aarch64" => "aarch64-apple-darwin",
            "x86_64" => "x86_64-apple-darwin",
            _ => panic!("Unsupported host architecture: {host_target}"),
        };
        run_cmd(
            "cargo",
            &["build", "--release", "--target", rust_target],
            &rust_dir,
        );
        fs::copy(
            target_dir.join(format!("{rust_target}/release/libpurr.a")),
            &output_lib,
        )
        .expect("Copy host static lib");
        println!("Built macOS static library ({rust_target} only)");
    }

    // --- iOS (always built) ---
    let ios_targets = ["aarch64-apple-ios", "aarch64-apple-ios-sim"];
    let installed_targets = installed_rust_targets();
    for target in &ios_targets {
        assert!(
            installed_targets.iter().any(|t| t == target),
            "Required Rust target {target} is not installed. \
             Run inside `nix develop` or add it to flake.nix targets."
        );
    }

    // iOS device (aarch64-apple-ios)
    println!("Building iOS device static library...");
    run_cmd_with_env(
        "cargo",
        &["build", "--release", "--target", "aarch64-apple-ios"],
        &rust_dir,
        &ios_cross_env("iphoneos"),
    );
    let ios_device_dir = swift_dest.join("ios-device");
    fs::create_dir_all(&ios_device_dir).expect("Create ios-device dir");
    fs::copy(
        target_dir.join("aarch64-apple-ios/release/libpurr.a"),
        ios_device_dir.join("libpurr.a"),
    )
    .expect("Copy iOS device static lib");
    println!("Copied iOS device static library");

    // iOS simulator (aarch64-apple-ios-sim)
    println!("Building iOS simulator static library...");
    run_cmd_with_env(
        "cargo",
        &["build", "--release", "--target", "aarch64-apple-ios-sim"],
        &rust_dir,
        &ios_cross_env("iphonesimulator"),
    );
    let ios_sim_dir = swift_dest.join("ios-simulator");
    fs::create_dir_all(&ios_sim_dir).expect("Create ios-simulator dir");
    fs::copy(
        target_dir.join("aarch64-apple-ios-sim/release/libpurr.a"),
        ios_sim_dir.join("libpurr.a"),
    )
    .expect("Copy iOS simulator static lib");
    println!("Copied iOS simulator static library");

    println!("Done! Bindings regenerated successfully.");
    println!("Generated files:");
    println!(
        "  - {}/purr.swift (UniFFI generated)",
        wrapper_dest.display()
    );
    println!("  - {}/purrFFI.h", swift_dest.display());
    println!("  - {}/module.modulemap", swift_dest.display());
    if universal {
        println!("  - {}/libpurr.a (macOS universal)", swift_dest.display());
    } else {
        println!("  - {}/libpurr.a (host arch only)", swift_dest.display());
    }
    println!("  - {}/ios-device/libpurr.a", swift_dest.display());
    println!("  - {}/ios-simulator/libpurr.a", swift_dest.display());
    println!();
    println!("Note: ClipKittyRust.swift is a manually maintained file (not generated).");
}

fn run_cmd(program: &str, args: &[&str], dir: &PathBuf) {
    run_cmd_with_env(program, args, dir, &[]);
}

fn run_cmd_with_env(program: &str, args: &[&str], dir: &PathBuf, env_vars: &[(String, String)]) {
    let mut cmd = Command::new(program);
    cmd.args(args).current_dir(dir);

    if !env_vars.is_empty() {
        // Start from the current environment, then apply overrides.
        // Remove Nix-injected vars that conflict with iOS cross-compilation.
        let mut env: std::collections::HashMap<String, String> = env::vars().collect();
        // NIX_CFLAGS_COMPILE and NIX_LDFLAGS inject macOS-specific flags
        env.remove("NIX_CFLAGS_COMPILE");
        env.remove("NIX_LDFLAGS");
        for (key, value) in env_vars {
            env.insert(key.clone(), value.clone());
        }
        cmd.env_clear().envs(env);
    }

    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("Failed to run {}: {}", program, e));

    if !status.success() {
        panic!("{} failed with status: {}", program, status);
    }
}

/// Resolve cross-compilation environment variables for an iOS SDK.
/// Uses `/usr/bin/xcrun` to find the SDK path and set CC/AR for C dependencies
/// that cargo builds from source. Forces `DEVELOPER_DIR` to the real Xcode
/// installation so it works inside Nix shells (which may override DEVELOPER_DIR
/// to point to a macOS-only SDK).
fn ios_cross_env(sdk: &str) -> Vec<(String, String)> {
    let xcrun = "/usr/bin/xcrun";

    // Resolve the real Xcode developer dir. Inside Nix shells, DEVELOPER_DIR
    // may point to a macOS-only SDK that lacks iOS platforms. We need the
    // actual Xcode installation for iOS cross-compilation.
    let xcode_dev_dir = resolve_xcode_developer_dir();

    let sdk_path = Command::new(xcrun)
        .env("DEVELOPER_DIR", &xcode_dev_dir)
        .args(["--sdk", sdk, "--show-sdk-path"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| panic!("Failed to resolve {} SDK path via xcrun", sdk));

    let cc = Command::new(xcrun)
        .env("DEVELOPER_DIR", &xcode_dev_dir)
        .args(["--sdk", sdk, "--find", "clang"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| panic!("Failed to find clang for {} SDK via xcrun", sdk));

    let ar = Command::new(xcrun)
        .env("DEVELOPER_DIR", &xcode_dev_dir)
        .args(["--sdk", sdk, "--find", "ar"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| panic!("Failed to find ar for {} SDK via xcrun", sdk));

    let deployment_target = "26.0";

    let (rust_target, cargo_target_upper) = match sdk {
        "iphoneos" => ("aarch64-apple-ios", "AARCH64_APPLE_IOS"),
        "iphonesimulator" => ("aarch64-apple-ios-sim", "AARCH64_APPLE_IOS_SIM"),
        _ => panic!("Unsupported iOS SDK: {sdk}"),
    };

    // Build a CC wrapper command that forces the correct SDK and target.
    // This is necessary because inside Nix shells, CC points to a Nix-wrapped
    // clang that hardcodes macOS sysroot/target flags.
    let cc_flags = format!(
        "-isysroot {sdk_path} -target {target} -miphoneos-version-min={deployment_target}",
        target = if sdk == "iphoneos" {
            "arm64-apple-ios26.0"
        } else {
            "arm64-apple-ios26.0-simulator"
        },
    );

    vec![
        // Override CC/AR at the target-specific level (cargo uses these for build scripts)
        (format!("CC_{}", rust_target.replace('-', "_")), cc.clone()),
        (format!("AR_{}", rust_target.replace('-', "_")), ar.clone()),
        (
            format!("CFLAGS_{}", rust_target.replace('-', "_")),
            cc_flags.clone(),
        ),
        // Also set the cargo linker override — this bypasses Nix's cc wrapper
        (
            format!("CARGO_TARGET_{cargo_target_upper}_LINKER"),
            cc.clone(),
        ),
        // Plain CC/AR for build scripts that don't check target-specific vars
        ("CC".into(), cc),
        ("AR".into(), ar),
        ("CFLAGS".into(), cc_flags),
        ("SDKROOT".into(), sdk_path),
        ("DEVELOPER_DIR".into(), xcode_dev_dir),
        (
            "IPHONEOS_DEPLOYMENT_TARGET".into(),
            deployment_target.into(),
        ),
    ]
}

/// Find the real Xcode developer directory, bypassing any DEVELOPER_DIR
/// override (e.g. from Nix shells that point to a macOS-only SDK).
fn resolve_xcode_developer_dir() -> String {
    // Try common Xcode locations first — faster than spawning a process and
    // works even when xcode-select itself respects the overridden DEVELOPER_DIR.
    let candidates = [
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer",
    ];
    for path in &candidates {
        let ios_platform = format!("{path}/Platforms/iPhoneOS.platform");
        if std::path::Path::new(&ios_platform).exists() {
            return path.to_string();
        }
    }

    // Fallback: ask xcode-select with a clean DEVELOPER_DIR
    Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .env_remove("DEVELOPER_DIR")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| candidates[0].to_string())
}

fn installed_rust_targets() -> Vec<String> {
    // Check the sysroot for installed target libraries.  This works with both
    // rustup-managed and Nix-managed toolchains (rustup metadata doesn't
    // reflect targets installed via Nix's rust-overlay).
    let sysroot = Command::new("rustc")
        .args(["--print", "sysroot"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());

    if let Some(sysroot) = sysroot {
        let rustlib = PathBuf::from(&sysroot).join("lib/rustlib");
        if let Ok(entries) = fs::read_dir(&rustlib) {
            return entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().join("lib").is_dir())
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|name| name.contains("-apple-"))
                .collect();
        }
    }

    Vec::new()
}
