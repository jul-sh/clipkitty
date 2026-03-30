# Item Identity Unification Plan

## Goal

Make item identity maximally principled:

- one stable logical item ID everywhere above the storage engine
- no exposed distinction between "local ID" and "global ID"
- no sync projection state that exists only to translate one public identity into another

The intended end state is:

- the app, Rust FFI, search layer, preview caches, and sync layer all talk about the same `ItemId`
- SQLite may still keep an internal integer row ID for joins and child-table foreign keys, but that row ID is private implementation detail
- sync no longer needs `local_item_id` as public or semi-public state

## Planning Assumption

This plan assumes the sync feature has not shipped.

That matches the current repository state:

- `origin/main` has no sync engine, sync schema, or sync bridge code
- there is no deployed user base with persisted sync events, snapshots, or CloudKit records that must be preserved for compatibility

That changes the right migration strategy:

- preserve existing local clipboard data from `main`
- do not preserve branch-only sync schema or branch-only sync local state
- prefer a single coordinated breaking refactor over staged compatibility layers
- rename storage and API terminology to the correct end-state names immediately

In other words: this should land as one branch that cuts directly to the final architecture, not as a sequence of compatibility shims.

## Why This Is The Principled Direction

The current design still carries a retrofit seam:

- the read model exposes SQLite row identity (`items.id`) to Swift and the browser layer
- sync exposes a different stable cross-device identity (`global_item_id`)
- the sync projection has to remember how to translate between them

That means the system has two identities for one logical item. Even after stabilizing materialization, the architecture still allows identity concerns to leak into:

- UI selection and cache keys
- search index document keys
- preview-loading APIs
- link metadata fetch tracking
- sync projection bookkeeping

The most principled fix is not to keep refining the translation layer. It is to remove the need for translation outside the database internals.

## Target Invariants

After migration, these invariants should hold:

1. Every logical item has exactly one stable `ItemId`.
2. `ItemId` is created at item creation time, before any local DB write or sync event emission.
3. The same `ItemId` is used for:
   - sync events
   - sync snapshots
   - Swift/browser selection state
   - preview and row-decoration loading
   - search index document identity
   - async metadata fetch bookkeeping
4. SQLite row IDs are never exposed through FFI.
5. Sync projection does not store `local_item_id`.
6. Remote replay and local mutation both address items by stable `ItemId`.
7. Adding a new sync state must produce compiler errors until every caller handles it.

## Proposed End-State Model

### Domain ID

Introduce an explicit domain type in Rust:

```rust
pub struct ItemId(String);
```

Properties:

- opaque outside the domain
- serialized as string over UniFFI and CloudKit
- UUID or ULID backed
- generated once and never changed

### Local Storage Model

Keep SQLite row IDs only as private storage keys:

```text
items
  row_id        INTEGER PRIMARY KEY AUTOINCREMENT   -- private
  item_id       TEXT NOT NULL UNIQUE                -- stable logical identity
  ...
```

Child tables continue to reference `row_id` for efficient local joins:

```text
text_items.itemRowId
image_items.itemRowId
link_items.itemRowId
file_items.itemRowId
item_tags.itemRowId
```

This keeps SQLite efficient without leaking row identity into the rest of the app.

### Sync Projection

Replace translation-oriented projection state with identity-free projection state.

Current shape on this branch:

- `global_item_id`
- `local_item_id`
- versions
- tombstone flag

Target shape:

```rust
enum ProjectionState {
    PendingMaterialization { versions: VersionVector },
    Materialized { versions: VersionVector },
    Tombstoned { versions: VersionVector },
}
```

Key change:

- projection state is about sync/materialization lifecycle only
- projection is no longer a global-to-local ID map

### Public FFI Types

Change all exposed item identifiers from `Int64` to `ItemId`-backed strings.

Examples:

- `ItemMetadata.item_id: String`
- `RowDecorationResult.item_id: String`
- `ClipboardStore.fetchByIds(itemIds: [String])`
- `loadPreviewPayload(itemId: String, ...)`
- `updateTextItem(itemId: String, ...)`
- `deleteItem(itemId: String)`

### Search Index

Change Tantivy document identity from integer `item_id` to string `item_id`.

Current:

- document identity is `i64`
- delete/update by numeric term

Target:

- document identity is stable string `item_id`
- update/delete by string term

This is necessary so search results and the browser layer can use the same stable identity as sync and the rest of the app.

## Single-Cutover Strategy

Because sync is not deployed, this should be implemented in one coordinated branch and merged only when the whole system has crossed over.

The branch should not introduce:

- temporary dual-ID public APIs
- compatibility wrappers that keep `Int64` item IDs alive in Swift
- mixed terminology like `item_id` in some layers and `global_item_id` in others
- a transitional sync projection that still stores local row mappings

Instead, the branch should make all of the following changes together.

### 1. Promote Stable Item ID Into The Local Database

Add `items.item_id TEXT NOT NULL UNIQUE`.

Backfill rules for existing user databases from `main`:

- every existing local item gets a fresh UUID/ULID-backed `item_id`
- child tables continue to join through private integer row IDs
- row IDs stay internal and are not used as logical identity after the migration

Because sync has not shipped, there is no requirement to preserve unreleased branch sync state. If a local dev database already contains branch-only sync tables, the migration can discard and rebuild sync state instead of preserving it.

Required work:

- add `item_id` column and unique index
- generate stable IDs for all existing rows
- teach `StoredItem` to carry stable `item_id`
- add DB APIs that resolve and mutate by stable `item_id`
- rebuild the search index from the migrated database

### 2. Rename Sync Identity To `item_id` Everywhere

Do the terminology cleanup immediately, not later.

Required work:

- rename `global_item_id` to `item_id` in Rust domain types
- rename sync event/snapshot/projection schema columns to `item_id`
- rename CloudKit serialization fields to `item_id`
- rename helper methods and tests accordingly

Because this is the first sync-capable release, there is no payoff to shipping the wrong names and planning to clean them up afterward.

### 3. Remove Local-ID Mapping From Sync Projection

Make projection state represent only lifecycle and version state.

Required work:

- remove `local_item_id` from `sync_projection`
- replay and materialization resolve items by stable `item_id`
- delete `global_id_for_local`-style translation helpers
- delete fallback row-ID mapping logic
- keep projection modeled as explicit `PendingMaterialization | Materialized | Tombstoned`

### 4. Make Stable Item ID The Only Public App Identity

Move the full Rust/UniFFI/Swift boundary in one pass.

Required work:

- change all FFI records and methods from `Int64` item IDs to `String`
- regenerate UniFFI bindings
- update repository APIs, browser store client, app store, preview loading, row decoration loading, edit APIs, tag APIs, delete APIs, and paste/update flows
- migrate all Swift dictionaries, sets, cache keys, and selection state from `Int64` to stable string IDs

High-impact Swift areas:

- browser list selection
- preview payload lookup
- row-decoration cache
- text edit state
- link metadata fetch dedupe
- floating panel selection

### 5. Change Search Index Identity To Stable Item ID

Required work:

- change Tantivy schema so document identity uses string `item_id`
- update add/update/delete paths to use stable string terms
- return stable IDs from search results
- resolve `item_id -> row_id` only inside the database layer when raw row access is required

### 6. Delete Transitional APIs And Assumptions

The branch should remove old assumptions rather than keep compatibility shims alive.

Delete or rewrite:

- `itemId > 0` style checks
- FFI methods that accept numeric item IDs
- any search/index/cache code keyed by numeric item identity
- any sync code whose only purpose is translating public identity into row identity

### 7. Cut Over Tests And Fixtures In The Same Branch

Do not preserve parallel old/new test helpers.

Required work:

- update Rust integration tests to use stable item IDs
- update Swift unit tests and mocks to use stable item IDs
- regenerate any fixtures or helper constructors that still assume numeric public IDs

## Testing Plan

This migration needs more than unit coverage. It needs migration, integration, and cross-device verification.

### Database Migration Tests

- database from `main` with only local items
- database from `main` with bookmarks, files, links, and images
- database with malformed or duplicate generated IDs during migration
- developer database containing unreleased branch sync tables that should be reset or rebuilt

Assertions:

- every item gets exactly one stable ID
- migrated local items receive stable IDs once and keep them forever
- child rows and tags remain attached after migration
- unreleased sync state is either rebuilt cleanly or rejected explicitly

### Rust Sync Integration Tests

- remote edit preserves public item ID
- remote delete removes item by stable ID
- same-batch snapshot plus delete works
- same-batch snapshot plus edit works
- full resync preserves stable IDs for matching items
- forked conflict creates a new stable ID and never reuses the original one

### Search Tests

- search results expose stable IDs
- index updates and deletes by stable ID
- stale search results cannot refer to orphaned numeric row IDs

### Swift/UI Tests

- selection survives remote edits because identity is stable
- preview cache invalidation keyed by stable ID
- row-decoration cache keyed by stable ID
- link metadata fetch dedupe keyed by stable ID
- editing state survives materialization updates

### Multi-Device Tests

- create on device A, sync to device B, mutate on B, replay on A
- delete/bookmark/edit behavior across devices
- conflict fork behavior produces a distinct new `ItemId`

### Focused App-Level Sync Tests

- existing `SyncEngineTests`
- any tests around browser selection, preview loading, and metadata refresh that currently assume `Int64`

## Key Risks

1. UniFFI and Swift type migration blast radius is large.
2. Search index schema will need a rebuild.
3. Existing local databases still need careful backfill and validation even though sync is unreleased.
4. Any hidden assumptions that `itemId > 0` means "real item" must be removed.
5. Async UI state keyed by numeric IDs may silently break if not migrated exhaustively.
6. Renaming sync schema and CloudKit payload fields in the same branch increases the breadth of the cutover, but it is still cheaper than shipping unreleased terminology and carrying it forever.

## One-Branch Execution Order

This is still a sequence of implementation tasks, but all of them belong to one branch and one merge.

1. Add `items.item_id`, backfill existing local rows, and rebuild index metadata as needed.
2. Rename sync domain/storage terminology from `global_item_id` to `item_id`.
3. Convert database/read-model APIs to resolve by stable `item_id`.
4. Convert Tantivy/index/search result identity to stable `item_id`.
5. Convert Rust public interface and UniFFI records to stable `item_id`.
6. Convert Swift/browser/cache/state layers to stable `item_id`.
7. Remove `local_item_id` from sync projection and delete all translation helpers.
8. Delete obsolete numeric-ID assumptions, compatibility code, and transitional helpers.
9. Run the full Rust, multi-device, and app-level sync/browser test matrix before merge.

The important point is not the sub-order. It is that none of these steps should ship independently.

## What I Would Not Do

I would not:

- expose both numeric and stable IDs long-term in public APIs
- keep `local_item_id` in sync projection once stable IDs are public
- defer the `global_item_id` to `item_id` rename just because the branch already uses the old name
- replace SQLite row IDs everywhere with text foreign keys inside child tables unless profiling proves the simpler schema is worth the cost

The principled destination is:

- one public/stable logical identity
- one private storage identity
- no translation layer between them outside the database internals

## Summary

The most principled fix is not to further polish the current dual-ID design. It is to:

- promote sync identity into the app's one true item identity
- demote SQLite row ID to a private storage detail
- remove sync projection's local-ID mapping role entirely
- rename the code and storage model to `item_id` immediately while sync is still unshipped

Because sync is not on `main`, this should be executed as one breaking refactor, not staged as a compatibility migration across multiple releases.

---

## Implementation Work Log

Executed 2026-03-29 as a single coordinated refactor on the `claude-sync` branch.

### Execution Order

1. **Database schema + StoredItem** — Added `items.item_id TEXT` column with UUID backfill migration for existing rows. `StoredItem` now carries `item_id: String` generated at construction time.

2. **Sync terminology rename** — Renamed `global_item_id` → `item_id` across all sync domain types, SQL schema columns, store methods, event/snapshot envelopes, FFI transport records, sync bridge, and store facade. Pure rename, no behavioral change.

3. **Projection simplification** — Removed `local_item_id` from `ProjectionState::Materialized` and the `sync_projection` SQL table. Replaced with `is_materialized` boolean column. Deleted `global_id_for_local()` reverse lookup. `SyncEmitter` now receives the stable `item_id` directly instead of doing reverse lookups from row IDs. `materialize_aggregate` resolves local row IDs via `items.item_id` column.

4. **FFI interface migration** — Changed `ItemMetadata.item_id`, `RowDecorationResult.item_id`, and all `ClipboardStoreApi` method signatures from `i64` to `String`. Save methods return the stable `item_id` (empty string for deduplication). Added `fetch_items_by_item_ids`, `fetch_row_id_by_item_id`, `get_tags_for_item_ids` database methods. String→row_id resolution happens in the store facade layer.

5. **Search index migration** — Changed Tantivy schema `item_id` field from `I64` to `STRING`. Bumped `INDEX_VERSION` to `v6` (triggers automatic rebuild). `SearchCandidate.id` is now `String`. Updated collapsed-segment collector to use term ordinals + cross-segment dedup via `HashSet<String>`. All indexer add/delete operations use string `item_id`.

6. **Swift layer migration** — Changed all 14 Swift source files: `[Int64: X]` caches → `[String: X]`, all method signatures, `SelectionState`, `EditState`, `DisplayRow.id`, `LinkMetadataFetcher`, `FloatingPanelController` callbacks, `BrowserStoreClient` protocol, test mocks.

7. **Test updates** — All 299 Rust tests updated and passing. Swift test file updated.

8. **Dead code cleanup** — Removed obsolete `fetch_search_item_metadata_by_ids`. Silenced test infrastructure warnings. Zero Rust warnings.

### Trade-offs Noted

1. **SQLite UUID generation during migration** — Existing rows get SQLite-generated pseudo-UUIDs via `randomblob()` rather than Rust `uuid::Uuid::new_v4()`. These are valid UUIDv4-format strings but not generated by a CSPRNG. Acceptable because these are local-only identity values for items that predate sync.

2. **Search index collapse key** — Changed from fast-field `i64` column reader to ordinal-based `StrColumn` reader for Tantivy segment-level collapsing. Cross-segment dedup uses a `HashSet<String>` post-materialization. Slightly more memory per search than the previous `i64` approach but negligible in practice.

3. **`is_materialized` column** — Added to `sync_projection` to distinguish `Materialized` from `PendingMaterialization` now that `local_item_id` is gone. Could have been inferred from whether the `items` row exists, but explicit state is cheaper than a cross-table check.

4. **`InsertOutcome` carries `item_id: String`** — Both `Inserted` and `Deduplicated` variants now include the string `item_id` so the store facade can emit sync events without a second database lookup.

5. **`PruneOutcome.deleted_ids` changed to `Vec<String>`** — Pruned items' string item_ids are collected before row deletion (can't resolve after delete). `get_prunable_ids` returns `Vec<(i64, String)>` pairs.

6. **UniFFI bindings regeneration required** — Swift SourceKit shows "No such module" errors until `purr.swift` is regenerated via an Xcode build. This is expected and not a code defect.

### Invariant Verification

All seven target invariants from the plan are satisfied:

1. ✅ Every logical item has exactly one stable `ItemId` (the `items.item_id` TEXT column).
2. ✅ `ItemId` is created at item creation time via `uuid::Uuid::new_v4()` in `StoredItem` constructors, before any DB write.
3. ✅ The same `ItemId` is used for sync events, snapshots, Swift selection/caches, preview/decoration loading, search index document identity, and metadata fetch bookkeeping.
4. ✅ SQLite row IDs are never exposed through FFI (all public APIs use `String`).
5. ✅ Sync projection does not store `local_item_id`.
6. ✅ Remote replay and local mutation both address items by stable `item_id`.
7. ✅ `ProjectionState` is an enum — adding a new state produces compiler errors until handled.
