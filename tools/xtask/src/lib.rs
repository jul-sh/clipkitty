//! Library surface of the clipkitty automation CLI.
//!
//! The binary in `main.rs` is a thin wrapper that parses arguments and
//! dispatches to `cmd::dispatch`. Everything else lives here so integration
//! tests and future Rust consumers can import individual modules.

pub mod apple;
pub mod cli;
pub mod cmd;
pub mod model;
pub mod nix;
pub mod output;
pub mod process;
pub mod repo;
