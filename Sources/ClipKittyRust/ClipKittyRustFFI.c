// ClipKittyRustFFI C wrapper
// This file exists to satisfy the C target requirement for the FFI bridge.
// The actual FFI symbols come from the Rust static library (libpurr.a).
//
// ┌─────────────────────────────────────────────────────────────────────────────┐
// │ DEPENDENCY MAP - These files must stay in sync:                             │
// │                                                                             │
// │ purr/ (Rust crate)                    ← Core engine                         │
// │   ↓ generates (cargo run --bin generate-bindings)                           │
// │ Sources/ClipKittyRust/purrFFI.h            ← C header (auto-generated)      │
// │ Sources/ClipKittyRust/libpurr.a            ← Static library (auto-built)    │
// │ Sources/ClipKittyRust/module.modulemap     ← Module map (auto-generated)    │
// │                                                                             │
// │ Project.swift links:                                                        │
// │   - ClipKittyRustFFI target → this file + purrFFI.h                         │
// │   - linkerSettings → libpurr                                                │
// └─────────────────────────────────────────────────────────────────────────────┘

#include "purrFFI.h"
