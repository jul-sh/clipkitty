# ClipKitty Architecture

## Overview

ClipKitty is a macOS clipboard manager with a Rust core and Swift UI, connected via UniFFI.

```
┌─────────────────────────────────────────────────────────────┐
│                     Swift UI (SwiftUI)                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ ContentView │  │ SearchField │  │ ClipboardItemCache  │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                    │              │
│         └────────────────┼────────────────────┘              │
│                          │                                   │
│                          ▼                                   │
│              ┌───────────────────────┐                       │
│              │   ClipKittyRust.swift │ ← Manual extensions   │
│              │  (Sendable, UTType,   │                       │
│              │   RelativeDateTime)   │                       │
│              └───────────┬───────────┘                       │
│                          │                                   │
│              ┌───────────▼───────────┐                       │
│              │ clipkitty_core.swift  │ ← Auto-generated      │
│              │   (UniFFI bindings)   │                       │
│              └───────────┬───────────┘                       │
└──────────────────────────┼──────────────────────────────────┘
                           │ FFI (C ABI)
┌──────────────────────────┼──────────────────────────────────┐
│                          ▼                                   │
│              ┌───────────────────────┐                       │
│              │    ClipboardStore     │ ← rust-core/src/      │
│              │   (Thread-safe API)   │    store.rs           │
│              └───────────┬───────────┘                       │
│                          │                                   │
│         ┌────────────────┼────────────────┐                  │
│         ▼                ▼                ▼                  │
│  ┌────────────┐  ┌─────────────┐  ┌─────────────┐            │
│  │  Database  │  │   Indexer   │  │SearchEngine │            │
│  │  (SQLite)  │  │  (Tantivy)  │  │  (Nucleo)   │            │
│  └────────────┘  └─────────────┘  └─────────────┘            │
│                                                              │
│                     Rust Core                                │
└──────────────────────────────────────────────────────────────┘
```

## Data Flow

### Search (ID + Hydration Pattern)

Optimized for 1M+ items. Search returns only IDs and highlight ranges, not full content.

```
User types "hello"
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: search("hello")                                   │
│    Payload: ~20 bytes                                       │
└─────────────────────────────────────────────────────────────┘
       │ FFI call (~0.005ms)
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Rust: Tantivy trigram search → 5000 candidates           │
│    Nucleo fuzzy re-rank → top 2000 matches                  │
│    Return: [(id, highlights), ...]                          │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Swift: SearchResult                                      │
│    - matches: [SearchMatch(item_id: 42, highlights: [...])  │
│    - total_count: 847                                       │
│    Payload: ~1-2 KB for 50 results                          │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Swift: Check in-memory cache                             │
│    - Cache hit: Use cached ClipboardItem                    │
│    - Cache miss: fetch_by_ids([missing_ids])                │
└─────────────────────────────────────────────────────────────┘
       │ (only on cache miss)
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. Rust: SELECT * FROM items WHERE id IN (...)              │
│    Return: [ClipboardItem, ...]                             │
└─────────────────────────────────────────────────────────────┘
```

### Save Item

```
Clipboard change detected
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: save_text(text, sourceApp, bundleId)              │
└─────────────────────────────────────────────────────────────┘
       │ FFI call
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Rust: Content detection (URL, email, phone, etc.)        │
│    Hash content for deduplication                           │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Check duplicate by hash                                  │
│    - Duplicate: Update timestamp, return 0                  │
│    - New: Insert into SQLite + Tantivy index                │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Return item ID (or 0 for duplicate)                      │
└─────────────────────────────────────────────────────────────┘
```

## Two-Layer Search

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Tantivy (Retrieval)                                │
│                                                             │
│ - Trigram tokenization (3-grams)                            │
│ - Fast narrowing: millions → ~5000 candidates               │
│ - Handles typos via trigram overlap                         │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: Nucleo (Precision)                                 │
│                                                             │
│ - Fuzzy scoring with matched character indices              │
│ - Re-ranks candidates by match quality                      │
│ - Returns indices for highlight rendering                   │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

```
clipkitty/
├── Sources/
│   ├── App/                      # Swift UI application
│   │   ├── ClipKittyApp.swift
│   │   ├── ContentView.swift
│   │   ├── ClipboardStore.swift  # Swift wrapper + caching
│   │   └── ...
│   ├── ClipKittyRust/            # FFI bridge (C target)
│   │   ├── ClipKittyRustFFI.c    # SPM C target placeholder
│   │   ├── clipkitty_coreFFI.h   # [generated] C header
│   │   ├── module.modulemap      # [generated] Clang module
│   │   └── libclipkitty_core.a   # [generated] Static library
│   └── ClipKittyRustWrapper/     # Swift bindings
│       ├── clipkitty_core.swift  # [generated] UniFFI types
│       └── ClipKittyRust.swift   # Manual Swift extensions
│
├── rust-core/
│   ├── src/
│   │   ├── lib.rs                # Crate root, namespace functions
│   │   ├── store.rs              # ClipboardStore (main API)
│   │   ├── database.rs           # SQLite operations
│   │   ├── indexer.rs            # Tantivy index
│   │   ├── search.rs             # Nucleo fuzzy matching
│   │   ├── models.rs             # Data types
│   │   ├── content_detection.rs  # URL/email/phone detection
│   │   ├── clipkitty_core.udl    # UniFFI interface definition
│   │   └── bin/
│   │       └── generate_bindings.rs  # Binding generator
│   └── Cargo.toml
│
├── Package.swift                 # Swift package manifest
├── Makefile                      # Build commands
└── architecture.md               # This file
```

## FFI Binding Chain

```
Source of truth:
    rust-core/src/clipkitty_core.udl

       │ cargo run --bin generate-bindings
       ▼
Generated files:
    Sources/ClipKittyRust/clipkitty_coreFFI.h
    Sources/ClipKittyRust/module.modulemap
    Sources/ClipKittyRust/libclipkitty_core.a
    Sources/ClipKittyRustWrapper/clipkitty_core.swift

Manual extensions (must sync with .udl):
    Sources/ClipKittyRustWrapper/ClipKittyRust.swift
```

## Type Mapping

| Rust (models.rs) | UDL | Swift |
|------------------|-----|-------|
| `ClipboardItem` | dictionary | struct |
| `ClipboardContent` | [Enum] interface | enum with associated values |
| `LinkMetadataState` | [Enum] interface | enum with associated values |
| `ClipboardStore` | interface | class |
| `SearchResult` | dictionary | struct |
| `SearchMatch` | dictionary | struct |
| `HighlightRange` | dictionary | struct |
| `FetchResult` | dictionary | struct |

## Performance Characteristics

| Operation | Latency | Notes |
|-----------|---------|-------|
| FFI call overhead | ~0.005ms | Direct C ABI, no serialization |
| Search (cold) | ~5-20ms | Tantivy disk read + Nucleo scoring |
| Search (warm) | ~1-5ms | Tantivy cached + Nucleo scoring |
| fetch_by_ids (10 items) | ~0.1ms | SQLite by primary key |
| save_text | ~1-2ms | SQLite insert + Tantivy index |
| Dedup check | ~0.05ms | SQLite hash lookup |

## Threading Model

```
┌─────────────────────────────────────────────────────────────┐
│ Swift (Main Thread)                                         │
│   - UI rendering                                            │
│   - User input handling                                     │
└─────────────────────────────────────────────────────────────┘
       │
       │ async/await (moves to background)
       ▼
┌─────────────────────────────────────────────────────────────┐
│ Swift (Background Thread)                                   │
│   - Calls into Rust via FFI                                 │
└─────────────────────────────────────────────────────────────┘
       │
       │ FFI call (same thread continues into Rust)
       ▼
┌─────────────────────────────────────────────────────────────┐
│ Rust (ClipboardStore)                                       │
│   - Thread-safe via Arc<Database> + Arc<Indexer>            │
│   - RwLock for writer access                                │
│   - Send + Sync implemented for UniFFI                      │
└─────────────────────────────────────────────────────────────┘
```

## Alternative Architectures Considered

### RPC (instead of FFI)

If process isolation were needed:

```
┌──────────────┐         ┌──────────────┐
│   Swift UI   │   RPC   │ Rust Daemon  │
│              │ ◄─────► │              │
│  + SQLite    │  0.05-  │  + Tantivy   │
│  (read-only) │  0.4ms  │  + SQLite    │
└──────────────┘         └──────────────┘
```

| Approach | Overhead | Use case |
|----------|----------|----------|
| Unix + MsgPack | ~0.05ms | Process isolation |
| XPC | ~0.08ms | macOS sandboxing |
| gRPC | ~0.4ms | Cross-platform |

Current FFI approach chosen for:
- Minimal latency (~0.005ms)
- Single binary deployment
- No IPC complexity
