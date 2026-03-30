//! Generate UniFFI Swift bindings for ClipKitty
//!
//! Run: cargo run --bin generate-bindings
//!
//! ┌─────────────────────────────────────────────────────────────────────────────┐
//! │ DEPENDENCY MAP - Output paths must match Project.swift expectations         │
//! │                                                                             │
//! │ Inputs:                                                                     │
//! │   target/release/libpurr.dylib       ← Built library for bindgen            │
//! │                                                                             │
//! │ Outputs (paths match Project.swift):                                        │
//! │   Sources/ClipKittyRust/purrFFI.h             ← C header                    │
//! │   Sources/ClipKittyRust/module.modulemap      ← Clang module map            │
//! │   Sources/ClipKittyRust/libpurr.a             ← Universal static lib        │
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
    let target_dir = project_root.join("target");

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

    // Build universal static library
    println!("Building static library...");
    let installed_targets = installed_rust_targets();
    let preferred_targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"];
    let available_targets: Vec<&str> = preferred_targets
        .iter()
        .copied()
        .filter(|target| installed_targets.iter().any(|installed| installed == target))
        .collect();

    for target in &available_targets {
        run_cmd("cargo", &["build", "--release", "--target", target], &rust_dir);
    }

    let output_lib = swift_dest.join("libpurr.a");
    match available_targets.as_slice() {
        [single_target] => {
            let lib = target_dir.join(format!("{single_target}/release/libpurr.a"));
            fs::copy(lib, &output_lib).expect("Copy static lib");
            println!("Copied single-arch static library for {single_target}");
        }
        [first_target, second_target] => {
            let first_lib = target_dir.join(format!("{first_target}/release/libpurr.a"));
            let second_lib = target_dir.join(format!("{second_target}/release/libpurr.a"));
            run_cmd(
                "lipo",
                &[
                    "-create",
                    &first_lib.to_string_lossy(),
                    &second_lib.to_string_lossy(),
                    "-output",
                    &output_lib.to_string_lossy(),
                ],
                &rust_dir,
            );
            println!("Created universal static library");
        }
        _ => {
            fs::copy(target_dir.join("release/libpurr.a"), &output_lib)
                .expect("Copy host static lib");
            println!("Copied host-arch static library");
        }
    }

    println!("Done! Bindings regenerated successfully.");
    println!("Generated files:");
    println!(
        "  - {}/purr.swift (UniFFI generated)",
        wrapper_dest.display()
    );
    println!("  - {}/purrFFI.h", swift_dest.display());
    println!("  - {}/module.modulemap", swift_dest.display());
    println!("  - {}/libpurr.a", swift_dest.display());
    println!();
    println!("Note: ClipKittyRust.swift is a manually maintained file (not generated).");
}

fn run_cmd(program: &str, args: &[&str], dir: &PathBuf) {
    let status = Command::new(program)
        .args(args)
        .current_dir(dir)
        .status()
        .unwrap_or_else(|e| panic!("Failed to run {}: {}", program, e));

    if !status.success() {
        panic!("{} failed with status: {}", program, status);
    }
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
                .filter(|name| name.contains("-apple-darwin"))
                .collect();
        }
    }

    Vec::new()
}
