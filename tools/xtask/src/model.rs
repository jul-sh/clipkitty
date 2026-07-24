//! Typed domain model for automation state.
//!
//! The CLI deliberately avoids stringly-typed `"Hardened"` / `"AppStore"` flows.
//! Every command receives and returns enums/structs so illegal states
//! (unsigned AppStore upload, Debug signing identity, cross-platform mismatches)
//! become unrepresentable at the boundary.

use clap::ValueEnum;

/// macOS build/distribution variant — maps 1:1 to nix package names.
///
/// Value names match the canonical build/signing names used throughout the
/// repository (`Release`, `Debug`, `Hardened`, `SparkleRelease`, `AppStore`),
/// with lowercase aliases for call sites that prefer kebab-case.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum MacVariant {
    #[value(name = "Debug", alias = "debug")]
    Debug,
    #[value(name = "Release", alias = "release")]
    Release,
    #[value(name = "SparkleRelease", alias = "sparkle-release")]
    SparkleRelease,
    #[value(name = "Hardened", alias = "hardened")]
    Hardened,
    #[value(name = "AppStore", alias = "app-store")]
    AppStore,
}

impl MacVariant {
    /// Nix flake attribute name that builds this variant.
    pub fn nix_attr(self) -> &'static str {
        match self {
            Self::Release => "clipkitty",
            Self::Debug => "clipkitty-debug",
            Self::Hardened => "clipkitty-hardened",
            Self::SparkleRelease => "clipkitty-sparkle",
            Self::AppStore => "clipkitty-appstore",
        }
    }

    /// DerivedData configuration directory name.
    pub fn configuration_dir(self) -> &'static str {
        match self {
            Self::Release => "Release",
            Self::Debug => "Debug",
            Self::Hardened => "Hardened",
            Self::SparkleRelease => "SparkleRelease",
            Self::AppStore => "AppStore",
        }
    }
}

/// What an internal signing-setup step is being asked to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupAction {
    Init,
    Teardown,
}

/// Sparkle release channel for appcast state updates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ReleaseChannel {
    Stable,
    Beta,
}

impl ReleaseChannel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Beta => "beta",
        }
    }
}

/// Which App Store Connect credential field a command needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum AscAuthField {
    KeyId,
    IssuerId,
    PrivateKeyB64,
}
