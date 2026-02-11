// ClipKittyRustFFI C wrapper
// This file exists to satisfy Swift Package Manager's C target requirement.
// The actual FFI symbols come from the Rust static library (libclipkitty_core.a).
//
// ┌─────────────────────────────────────────────────────────────────────────────┐
// │ DEPENDENCY MAP - These files must stay in sync:                             │
// │                                                                             │
// │ purr/src/clipkitty_core.udl        ← FFI definitions                   │
// │   ↓ generates (cargo run --bin generate-bindings)                           │
// │ Sources/ClipKittyRust/clipkitty_coreFFI.h   ← C header (auto-generated)     │
// │ Sources/ClipKittyRust/libclipkitty_core.a   ← Static library (auto-built)   │
// │ Sources/ClipKittyRust/module.modulemap      ← Module map (auto-generated)   │
// │                                                                             │
// │ Package.swift links:                                                        │
// │   - ClipKittyRustFFI target → this file + clipkitty_coreFFI.h               │
// │   - linkerSettings → libclipkitty_core                                      │
// └─────────────────────────────────────────────────────────────────────────────┘

#include "clipkitty_coreFFI.h"
