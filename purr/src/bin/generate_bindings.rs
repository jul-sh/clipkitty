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

    // Ensure Rust is built with the same deployment target as the Swift app
    env::set_var("MACOSX_DEPLOYMENT_TARGET", "15.0");

    println!("Building Rust library...");
    run_cmd("cargo", &["build", "--release"], &rust_dir);

    println!("Generating Swift bindings...");
    run_cmd(
        "cargo",
        &[
            "run",
            "--bin",
            "uniffi-bindgen",
            "generate",
            "--library",
            "target/release/libpurr.dylib",
            "--language",
            "swift",
            "--out-dir",
            "generated",
        ],
        &rust_dir,
    );

    let swift_dest = project_root.join("Sources/ClipKittyRust");
    let wrapper_dest = project_root.join("Sources/ClipKittyRustWrapper");
    let generated = rust_dir.join("generated");

    // Read and fix Swift 6 concurrency + module import
    println!("Copying generated Swift file...");
    let mut swift_content =
        fs::read_to_string(generated.join("purr.swift")).expect("Read swift file");
    swift_content = swift_content.replace(
        "private var initializationResult",
        "nonisolated(unsafe) private var initializationResult",
    );
    swift_content = swift_content.replace(
        "#if canImport(purrFFI)",
        "#if canImport(ClipKittyRustFFI)",
    );
    swift_content = swift_content.replace("import purrFFI", "import ClipKittyRustFFI");
    fs::write(wrapper_dest.join("purr.swift"), swift_content).expect("Write swift");

    // Copy header
    fs::copy(
        generated.join("purrFFI.h"),
        swift_dest.join("purrFFI.h"),
    )
    .expect("Copy header");

    // Write modulemap
    println!("Writing modulemap...");
    fs::write(
        swift_dest.join("module.modulemap"),
        "module ClipKittyRustFFI {\n    header \"purrFFI.h\"\n    export *\n}\n",
    )
    .expect("Write modulemap");

    // Build universal static library
    println!("Building universal static library...");
    run_cmd(
        "cargo",
        &["build", "--release", "--target", "aarch64-apple-darwin"],
        &rust_dir,
    );
    run_cmd(
        "cargo",
        &["build", "--release", "--target", "x86_64-apple-darwin"],
        &rust_dir,
    );

    run_cmd(
        "lipo",
        &[
            "-create",
            "target/aarch64-apple-darwin/release/libpurr.a",
            "target/x86_64-apple-darwin/release/libpurr.a",
            "-output",
            &swift_dest.join("libpurr.a").to_string_lossy(),
        ],
        &rust_dir,
    );

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
