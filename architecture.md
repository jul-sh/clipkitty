# ClipKitty Architecture

## Overview

ClipKitty is a macOS clipboard manager with a Rust core and Swift UI, connected via UniFFI.

```
┌─────────────────────────────────────────────────────────────┐
│                     Swift UI (SwiftUI)                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ ContentView │  │ SearchField │  │     ItemRow         │  │
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

## Data Types

### Core Types

| Type | Description |
|------|-------------|
| `ItemMetadata` | Lightweight item info for list display (id, icon, preview, source app, timestamp) |
| `ItemIcon` | Icon enum: Symbol (SF Symbol), ColorSwatch (RGBA u32), or Thumbnail (JPEG bytes) |
| `IconType` | Content type enum: Text, Link, Email, Phone, Address, DateType, Transit, Image, Color |
| `ClipboardItem` | Full item with metadata + content + preview highlights |
| `ClipboardContent` | Content enum: Text, Color, Link, Email, Phone, Address, Date, Transit, Image |

### Search Types

| Type | Description |
|------|-------------|
| `SearchResult` | Search response with ItemMatch array and total count |
| `ItemMatch` | Match result with ItemMetadata + MatchData |
| `MatchData` | Match text snippet with highlight ranges and line number |
| `HighlightRange` | Byte range (start, end) for highlighting |

### Fetch Types

| Type | Description |
|------|-------------|
| `FetchResults` | Paginated list response with ItemMetadata array, total count, and hasMore flag |

## Data Flow

### Browse Mode (No Search)

```
User opens panel
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: fetchItems(beforeTimestamp, limit)                │
│    Returns: FetchResults { items: [ItemMetadata], ... }     │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Display list using ItemMetadata (lightweight)            │
│    - Icon from ItemIcon (thumbnail, color swatch, or symbol)│
│    - Preview text (first line)                              │
│    - Source app badge                                       │
└─────────────────────────────────────────────────────────────┘
       │ User selects item
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Swift: fetchByIds([id], searchQuery: nil)                │
│    Returns: [ClipboardItem] with full content               │
│    - previewHighlights: [] (no search query)                │
└─────────────────────────────────────────────────────────────┘
```

### Search Mode (Short Query < 3 chars)

```
User types "he"
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: search("he")                                      │
└─────────────────────────────────────────────────────────────┘
       │ FFI call
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Rust: Short query search                                 │
│    a) Prefix match on recent 20K items via SQLite LIKE      │
│    b) Score: prefix boost * recency factor                  │
│    c) Generate match snippets with highlights               │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Returns: SearchResult                                    │
│    - matches: [ItemMatch] with:                             │
│      - itemMetadata: lightweight item info                  │
│      - matchData: { text, highlights, lineNumber }          │
│    - totalCount                                             │
└─────────────────────────────────────────────────────────────┘
```

### Search Mode (Trigram Query >= 3 chars)

```
User types "hello"
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: search("hello")                                   │
└─────────────────────────────────────────────────────────────┘
       │ FFI call
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Rust: Tantivy trigram search → 30K candidates            │
│    Nucleo fuzzy re-rank → top 5K matches                    │
│    Generate match snippets with highlights                  │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Returns: SearchResult                                    │
│    - matches: [ItemMatch] with all match data               │
│    - totalCount                                             │
│                                                             │
│ Note: All highlights computed by Rust, never in Swift       │
└─────────────────────────────────────────────────────────────┘
```

### Save Item

```
Clipboard change detected
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Swift: save_text(text, sourceApp, bundleId)              │
│    or: save_image(imageData, sourceApp, bundleId)           │
└─────────────────────────────────────────────────────────────┘
       │ FFI call
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Rust: Content detection                                  │
│    - Color (hex, rgb, hsl) → store RGBA value               │
│    - URL, email, phone, address, date, transit              │
│    - Hash content for deduplication                         │
│    - For images: generate thumbnail (48x48 JPEG)            │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Check duplicate by hash                                  │
│    - Duplicate: Update timestamp, return existing ID        │
│    - New: Insert into SQLite + Tantivy index                │
└─────────────────────────────────────────────────────────────┘
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Return item ID                                           │
└─────────────────────────────────────────────────────────────┘
```

## Two-Layer Search

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Tantivy (Retrieval)                                │
│                                                             │
│ - Trigram tokenization (3-grams)                            │
│ - Fast narrowing: millions → ~30K candidates                │
│ - Long queries (10+ trigrams): 2/3 must match               │
│ - Returns id, content, timestamp for each candidate         │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: Nucleo (Precision)                                 │
│                                                             │
│ - Fuzzy scoring with matched character indices              │
│ - Re-ranks candidates by match quality                      │
│ - Density check: 25% adjacent pairs required (words >3 ch)  │
│ - Missing atom exclusion: all query words must match        │
│ - Trailing space boost: 20% if match ends at whitespace     │
│ - Returns top 5K results                                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Ranking                                                     │
│                                                             │
│ Final score: nucleo_score * (1 + 0.1 * recency_factor)      │
│ - Multiplicative boost preserves quality ordering           │
│ - Recency: exponential decay with 7-day half-life           │
│ - Max 10% boost for brand-new items                         │
│ - Prefix matches get 2x boost (for short queries)           │
│ - Exact matches always beat fuzzy                           │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

```
clipkitty/
├── Sources/
│   ├── App/                      # Swift UI application
│   │   ├── ClipKittyApp.swift
│   │   ├── ContentView.swift     # Main UI with list + preview
│   │   ├── ClipboardStore.swift  # Swift wrapper, state management
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
│   │   ├── search.rs             # Nucleo fuzzy matching + highlighting
│   │   ├── models.rs             # Data types (ItemMetadata, ItemIcon, etc.)
│   │   ├── content_detection.rs  # URL/email/phone/color detection
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

| Rust | UDL | Swift |
|------|-----|-------|
| `ItemMetadata` | dictionary | struct |
| `ItemIcon` | [Enum] interface | enum with associated values |
| `IconType` | enum | enum |
| `ClipboardItem` | dictionary | struct |
| `ClipboardContent` | [Enum] interface | enum with associated values |
| `LinkMetadataState` | [Enum] interface | enum with associated values |
| `ClipboardStore` | interface | class |
| `SearchResult` | dictionary | struct |
| `ItemMatch` | dictionary | struct |
| `MatchData` | dictionary | struct |
| `HighlightRange` | dictionary | struct |
| `FetchResults` | dictionary | struct |

### Internal Search Types (not exposed via FFI)

| Rust Type | Description |
|-----------|-------------|
| `SearchCandidate` | Tantivy result with id, content, timestamp |
| `FuzzyMatch` | Nucleo match with id, score, matched_indices, timestamp, is_prefix_match |
| `StoredItem` | Internal item with thumbnail and colorRgba for DB storage |

## Performance Characteristics

| Operation | Latency | Notes |
|-----------|---------|-------|
| FFI call overhead | ~0.005ms | Direct C ABI, no serialization |
| Search (cold) | ~5-20ms | Tantivy disk read + Nucleo scoring |
| Search (warm) | ~1-5ms | Tantivy cached + Nucleo scoring |
| Short query search | ~0.5-2ms | SQLite LIKE on last 20K items |
| fetch_by_ids (10 items) | ~0.1ms | SQLite by primary key |
| fetchItems (50 items) | ~0.5ms | Keyset pagination |
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

## Key Design Decisions

### Highlights Always Computed by Rust

All text highlighting is computed by Rust and passed to Swift:
- `MatchData.highlights` for search result list items
- `ClipboardItem.previewHighlights` for preview pane
- Swift never re-computes highlights from the query

### Lightweight List Display

The item list uses `ItemMetadata` instead of full `ClipboardItem`:
- Only fetches what's needed for list display
- Icon, preview text, source app, timestamp
- Full content fetched only for selected item

### Color Detection in Rust

Color detection moved from Swift to Rust:
- Detects hex (#RGB, #RRGGBB, #RRGGBBAA), rgb(), rgba(), hsl(), hsla()
- Stores RGBA as u32 in database (colorRgba column)
- Returns `ItemIcon.colorSwatch` for display
- Returns `ClipboardContent.color` for full item

### Thumbnail Generation

Images get 48x48 JPEG thumbnails:
- Generated on save via `image` crate
- Stored in thumbnail BLOB column
- Returned in `ItemIcon.thumbnail`
- Avoids loading full image for list display
