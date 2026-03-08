# ClipKitty Refactor Roadmap

## Spec

### Phase 0. Baseline
- [x] Review the current Swift and Rust architecture against the requested roadmap
- [x] Keep `tasks/todo.md` updated while work progresses
- [x] Keep `tasks/lessons.md` available for future corrections and project rules

### Phase 1. Correctness First
- [x] Move link metadata loading out of `ContentView` and into explicit orchestration
- [x] Prevent stale metadata completions from overwriting newer preview state
- [x] Add regression coverage for rapid navigation during metadata fetch
- [x] Replace optimistic delete behavior with explicit pending/committed/failed handling and rollback
- [x] Replace optimistic clear behavior with explicit pending/committed/failed handling and rollback
- [x] Add failure-path tests for delete and clear rollback
- [x] Propagate cancellation through production Rust hydration paths
- [x] Treat SQLite interruption as cancellation, not empty success
- [x] Add cancellation timing tests for large result sets
- [x] Surface database inconsistency errors instead of default-looking fallback values
- [x] Add corruption/inconsistency tests

### Phase 2. Service Boundaries
- [x] Introduce app-side service boundaries for repository, preview loading, ingest, paste, and pasteboard monitoring
- [x] Remove direct global API use where shared protocols should own the boundary
- [x] Expand shared infrastructure protocols to cover monitoring and app/workspace/file-system use cases
- [x] Remove duplicate test-only protocol definitions and make tests use the shared abstractions
- [x] Eliminate duplicate thumbnail work in image ingest and return typed ingest results
- [x] Keep generated Swift bindings generated-only and route any type changes through Rust + regeneration

### Phase 3. Enum-Driven Browser State
- [x] Replace fragmented browser state with explicit session enums/records
- [x] Introduce a single browser reducer/view-model entry point
- [x] Move search debounce, selection, preview loading, metadata refresh, delete/clear flows, and overlay transitions into the browser feature layer
- [x] Make `ContentView` a presentation shell that renders state and emits events only
- [x] Remove ordered `.onChange` chains as the source of feature behavior
- [x] Keep overlay rendering directly driven by enum cases

### Phase 4. File Ownership and Simplification
- [x] Split the browser UI into focused files under `Sources/App/Browser/`
- [x] Split `ClipboardStore.swift` responsibilities into cohesive services/facades
- [x] Split `SettingsView.swift` into tab-specific files
- [x] Simplify `FloatingPanelController` state to only the behavior actually required
- [x] Rework launch-at-login state so transient failures remain actionable without restart

### Phase 5. Rust Core Restructure
- [x] Split Rust orchestration into `search_service.rs`, `save_service.rs`, and a thin UniFFI-facing facade
- [x] Extract shared search helpers instead of duplicating neighboring entry points
- [x] Extract shared save/dedupe helpers for text/file/image flows
- [x] Strengthen `LinkMetadataState` so loaded states carry meaningful payloads only
- [x] Regenerate UniFFI bindings after Rust source-model changes
- [x] Replace misleading image hash semantics with real content hashing or remove misleading pseudo-dedupe behavior

### Phase 6. Verification
- [x] Add Swift feature tests for browser state transitions, preview generation, stale async completion handling, destructive rollback, and launch-at-login retry
- [x] Add Rust tests for cancellation propagation, corruption paths, helper-level orchestration, and image hashing semantics
- [ ] Add integration/UI coverage for search-preview-metadata flow, ingest flows, reopen/reset behavior, overlay keyboard behavior, and command-number shortcuts
- [x] Run `cargo test` in `purr/`
- [ ] Run `make unittest`
- [ ] Run `make uitest`
- [x] Confirm generated bindings are synchronized

## Review
- Implemented the browser feature as enum-driven session state under `Sources/App/Browser/` with a single `BrowserViewModel`, moved stale metadata/preview protection into orchestration, and made delete/clear flows rollback-capable.
- Extracted Swift services for repository, preview loading, image ingest, paste, and pasteboard monitoring; simplified `FloatingPanelController`; and rebuilt launch-at-login around explicit actionable states.
- Split Rust store orchestration into `search_service.rs` and `save_service.rs`, propagated cancellation through production hydration, surfaced database inconsistencies as errors, strengthened link metadata modeling, and switched image dedupe to SHA-256 content hashing.
- Verification completed:
  - `cargo test` passed in `purr/` with `132` unit tests plus integration/doc tests green.
  - `xcodebuild -workspace ClipKitty.xcworkspace -scheme ClipKitty -destination 'platform=macOS' -derivedDataPath DerivedData build` passed.
  - `xcodebuild build-for-testing -workspace ClipKitty.xcworkspace -scheme ClipKitty -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedDataBuildForTesting CODE_SIGNING_ALLOWED=NO` passed.
  - `xcodebuild build-for-testing -workspace ClipKitty.xcworkspace -scheme ClipKittyUITests -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedDataUITestBuildForTesting CODE_SIGNING_ALLOWED=NO` passed.
- Verification blockers in this environment:
  - `make unittest` now reaches the runtime launch phase, but `xcodebuild test` aborts before executing tests because the local runner cannot establish communication with `com.apple.testmanagerd.control`.
  - `make uitest` no longer fails on the original scheme/signing configuration, but `xcodebuild test` still fails while signing the generated `ClipKittyUITests.xctest` bundle in the local macOS runner path (`invalid or unsupported format for signature` in `ClipKittyUITests.cstemp`).
