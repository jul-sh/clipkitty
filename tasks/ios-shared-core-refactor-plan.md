# iOS Shared-Core Refactor Plan

## Goal

Refactor ClipKitty so a future iOS app can reuse the maximum sensible amount of code without forcing the macOS app into an awkward lowest-common-denominator architecture.

The target is:

- Rust remains the source of truth for storage, search, sync, and durable domain invariants.
- Shared Swift owns Apple-platform application logic, feature state machines, and orchestration.
- macOS and iOS each own only their shell-specific integrations and UI surfaces.

## Product Reality Check

This plan is explicitly for a future separate iOS app, not for pretending macOS and iOS have the same product shell.

We should plan to share:

- history, search, ranking results, preview semantics
- item editing, deletion, tagging, bookmarking
- sync orchestration and CloudKit transport
- OCR and link metadata enrichment
- repository abstractions and feature state machines

We should not plan to share:

- menu bar integration
- floating panel behavior
- global hotkeys
- synthetic paste to the previously active app
- launch-at-login
- AppKit-specific rich preview rendering

## Non-Goals

- Do not rewrite the app so all application logic lives in Rust.
- Do not chase full UI parity between macOS and iOS at this stage.
- Do not share top-level SwiftUI screens unless they remain ergonomic on both platforms.
- Do not collapse platform differences behind boolean flags and `#if` noise inside shared code.

## Architecture Principles

- Enforce one-way dependencies: app target -> platform adapter -> shared Swift -> Rust bridge -> Rust core.
- Keep shared modules free of `AppKit`.
- Prefer sum types over optional fields and parallel booleans.
- Push validation to boundaries. Once shared state exists, it should already be valid.
- Remove global singletons from shared code paths.
- Treat platform capabilities as explicit enums, not scattered conditionals.
- Prefer thin app shells and thick shared feature modules.

## Proposed Target Graph

### `ClipKittyRust`

Existing Rust core plus UniFFI bindings.

Responsibilities:

- storage and migrations
- search and preview payload generation
- clipboard item domain models
- sync domain models and event sourcing

Rules:

- no SwiftUI, AppKit, or shell policy
- continue to be the strongest invariant boundary

### `ClipKittyShared`

New cross-platform Swift library for Apple-platform application logic.

Responsibilities:

- repository protocols and adapters
- feature state machines
- browser/search session logic
- mutation workflows
- shared settings value types
- formatting and intent models that do not require AppKit

Rules:

- no `AppKit`
- no global `AppSettings.shared`
- no windowing or menu bar code

### `ClipKittyAppleServices`

New Apple-only shared library for services that are valid on both macOS and iOS.

Responsibilities:

- `SyncEngine`
- CloudKit transport
- OCR/image description generation
- link metadata fetching
- image processing helpers using CoreGraphics/ImageIO instead of AppKit

Rules:

- no `AppKit`
- may use `CloudKit`, `Vision`, `LinkPresentation`, `UniformTypeIdentifiers`, `Foundation`

### `ClipKittyMacPlatform`

New macOS-only library.

Responsibilities:

- pasteboard monitoring and writing
- app activation and synthetic paste
- hotkeys
- menu bar and floating panel
- launch-at-login
- Sparkle
- AppKit-specific rendering and panel UI

### `ClipKittyIOSPlatform`

Future iOS-only library. Don't impl for now.

Responsibilities:

- foreground pasteboard reads/writes
- share-extension or import-entry integration
- scene lifecycle
- iOS-specific affordances for selection, preview, and paste workflows

### App Targets

- `ClipKittyMacApp`: thin composition root over `ClipKittyMacPlatform`
- `ClipKittyIOSApp`: future thin composition root over `ClipKittyIOSPlatform` # future

## Current Blockers

### 1. Build graph is still macOS-app-centric

The current project has one macOS app target plus the Rust wrapper target. Shared Swift logic still lives under `Sources/App/**`.

Impact:

- shared code cannot be compiled independently
- reuse is blocked by target shape before code shape

### 2. `ClipboardStore` is a monolith

`Sources/App/ClipboardStore.swift` currently mixes:

- bootstrap and database lifecycle
- repository access
- search orchestration
- pasteboard monitoring
- ingestion
- metadata enrichment
- sync wiring
- display invalidation
- paste execution

Impact:

- hard to extract safely
- hard to compile cross-platform
- encourages platform coupling inside core workflows

### 3. Shared logic still depends on app globals

`AppSettings.shared` leaks into feature and service code.

Impact:

- shared modules cannot be pure
- test setup stays heavier than necessary
- iOS shell would inherit macOS assumptions

### 4. Rust Swift wrapper is not yet cross-platform-clean

The manual UniFFI wrapper still imports `AppKit`.

Impact:

- the obvious reuse boundary still carries macOS-only baggage

### 5. Some Apple-wide services still live in the macOS app target

Examples:

- `SyncEngine`
- `ImageDescriptionGenerator`
- `LinkMetadataFetcher`

Impact:

- good shared code is trapped behind the wrong target

## Delegation Strategy

Sequence the work so delegates can move in parallel without merge thrash.

### Lane A: Foundation

- target graph extraction
- Rust wrapper cleanup
- shared settings models and dependency injection seams

### Lane B: Shared feature extraction

- browser session state
- browser view model
- repository boundary cleanup

### Lane C: Service decomposition

- split `ClipboardStore`
- move Apple-wide services into shared libraries

### Lane D: Platform shells

- isolate macOS-only pieces
- scaffold future iOS shell after shared seams stabilize

Recommended merge order:

1. target graph and wrapper cleanup
2. settings/env extraction
3. browser feature extraction
4. `ClipboardStore` decomposition
5. Apple services extraction
6. macOS shell isolation
7. iOS scaffold

## Workstreams

## W1. Target Graph Extraction

Suggested owner: build/tooling

Scope:

- add new library targets in `Project.swift`
- stop building all shared logic through `Sources/App/**`
- create new source roots for shared/platform code

Primary files:

- `Project.swift`
- new `Sources/Shared/**`
- new `Sources/AppleServices/**`
- new `Sources/MacPlatform/**`

Deliverables:

- new targets compile in the current macOS app
- no behavior changes
- tests still run from the macOS scheme

Definition of done:

- `ClipKittyShared` exists and can compile independently of `AppKit`
- `ClipKittyAppleServices` exists and can compile independently of `AppKit`
- macOS app target depends on these libraries rather than owning all code directly

Out of scope:

- no feature rewrites
- no iOS target yet

## W2. Rust Wrapper Portability Cleanup

Suggested owner: core integration

Scope:

- split manual UniFFI extensions into platform-neutral and platform-specific pieces
- remove `AppKit` imports from the shared wrapper path
- keep generated and manual bindings usable by both macOS and iOS

Primary files:

- `Sources/ClipKittyRustWrapper/ClipKittyRust.swift`
- new shared wrapper extensions
- new macOS-only wrapper extensions if needed

Deliverables:

- wrapper compiles for shared Swift targets
- UI-only conveniences move out of the core wrapper

Definition of done:

- the shared wrapper uses only cross-platform Apple frameworks
- `NSRange` and icon/UTType helpers live in the right layer

Notes:

- If a helper is presentation-only, move it out.
- If a helper expresses domain meaning, keep it near the wrapper.

## W3. Shared Settings and Environment Boundary

Suggested owner: application architecture

Scope:

- replace direct `AppSettings.shared` reads in shared code with injected dependencies
- define value types for user preferences and capabilities
- define a narrow settings store protocol

Primary files:

- `Sources/App/Settings.swift`
- `Sources/App/Services/PasteboardMonitor.swift`
- `Sources/App/Browser/**`
- `Sources/App/ClipboardStore.swift`

New shared types to introduce:

- `UserPreferences`
- `PasteBehavior`
- `PrivacyPreferences`
- `SyncPreference`
- `PlatformCapabilities`

Required enum-driven state changes:

- represent paste execution as a sum type, not boolean-plus-permission checks
- represent platform capability differences explicitly

Deliverables:

- shared code no longer reaches into the singleton directly
- composition root maps persisted settings into shared value types

Definition of done:

- shared targets can be instantiated in tests without `AppSettings.shared`
- macOS app still persists settings through the existing store

## W4. Browser Feature Extraction

Suggested owner: feature/state-machine

Scope:

- move browser session models and view model into `ClipKittyShared`
- keep the current behavior stable
- convert UI callbacks into typed intents/effects where it improves portability

Primary files:

- `Sources/App/Browser/BrowserSession.swift`
- `Sources/App/Browser/BrowserStoreClient.swift`
- `Sources/App/Browser/BrowserViewModel.swift`
- `Tests/UnitTests/BrowserViewModelTests.swift`

Deliverables:

- browser state machine lives in shared Swift
- tests move with the shared feature
- macOS UI consumes the shared view model without behavior changes

Definition of done:

- browser feature compiles without `AppKit`
- existing unit tests still pass after relocation
- no macOS-only UI concerns remain inside the shared feature module

Out of scope:

- do not try to share `BrowserView.swift` yet
- do not move AppKit text rendering into shared code

## W5. `ClipboardStore` Decomposition

Suggested owner: application architecture

Scope:

- split `ClipboardStore` into smaller collaborators with explicit responsibilities

Target collaborators:

- `StoreBootstrapper`
- `HistoryRepository` or repository facade
- `SearchSessionService`
- `IngestionCoordinator`
- `MutationService`
- `PasteExecutionService`
- `SyncController`

Primary files:

- `Sources/App/ClipboardStore.swift`
- `Sources/App/Services/ClipboardRepository.swift`
- related services under `Sources/App/Services/**`

Required rules:

- shared collaborators must not know about panel visibility or AppKit windowing
- platform services should be injected through protocols
- feature-facing state should remain enum-driven

Deliverables:

- `ClipboardStore` becomes either a thin facade or disappears entirely
- search, ingestion, mutation, and sync can evolve independently

Definition of done:

- at least search/session, ingestion, and mutation live in separate types
- panel/display concerns no longer drive shared service shape

Dependency:

- do this after W3 so new services can depend on shared settings abstractions

## W6. Apple Shared Services Extraction

Suggested owner: Apple-platform services

Scope:

- move cross-Apple services into `ClipKittyAppleServices`
- remove remaining macOS-only assumptions from those services

Primary files:

- `Sources/App/Services/SyncEngine.swift`
- `Sources/App/ImageDescriptionGenerator.swift`
- `Sources/App/LinkMetadataFetcher.swift`
- `Sources/App/Services/PreviewLoader.swift`

Deliverables:

- `SyncEngine` lives outside the macOS app target
- image and metadata enrichment compile for both macOS and iOS

Definition of done:

- `LinkMetadataFetcher` no longer depends on `NSImage`
- OCR/image description generation compiles in the shared Apple target
- `PreviewLoader` depends only on shared repository and Apple services

## W7. macOS Platform Isolation

Suggested owner: macOS shell

Scope:

- gather all macOS-only integration points into `ClipKittyMacPlatform`
- turn the macOS app target into a thin composition root

Primary files:

- `Sources/App/AppDelegate.swift`
- `Sources/App/FloatingPanelController.swift`
- `Sources/App/HotKeyManager.swift`
- `Sources/App/Services/PasteboardMonitor.swift`
- `Sources/App/Services/PasteService.swift`
- `Sources/App/AppActivationService.swift`
- `Sources/App/LaunchAtLogin.swift`
- `Sources/App/Snackbar*.swift`
- AppKit-heavy browser view/rendering files

Deliverables:

- shell code clearly separated from shared feature logic
- macOS app mostly wires dependencies and presents UI

Definition of done:

- AppKit files live behind a macOS-only target boundary
- shared targets have no direct imports of these files

## W8. Future iOS Shell Scaffold

Suggested owner: iOS shell

Scope:

- add an iOS app target once shared seams are in place
- prove that the shared core is reusable

Initial iOS scope:

- history list
- search
- preview
- edit/delete/bookmark
- sync-backed content

Explicitly not required for v1 scaffold:

- background clipboard capture parity with macOS
- floating panel equivalent
- global hotkeys

Deliverables:

- iOS target builds
- shared core is consumed from the new app target
- one thin iOS composition root exists

Definition of done:

- iOS app uses shared browser/application code rather than copying it
- no macOS-only dependencies leak into the iOS target graph

## Cross-Cutting Refactor Rules

These apply to every workstream.

### Rule 1: Keep illegal states unrepresentable

When extracting shared state, prefer enums/discriminated unions over:

- optional sibling fields
- `isX` plus nullable payload
- parallel booleans

Examples to watch:

- paste execution state
- sync availability
- selection/loading/error states
- ingestion source and processing stage

### Rule 2: No convenience booleans that hide enum cases

Do not extract enums and then immediately re-flatten them into `isLoading`, `isReady`, or `shouldPaste` style booleans unless they represent real derived data needed for display.

### Rule 3: Separate shell state from feature state

Feature state belongs in shared modules.

Examples:

- query, selection, mutation, preview, and result state are shared
- panel visibility, menu bar behavior, window focus, hotkey registration are shell state

### Rule 4: Prefer protocols at platform boundaries, not inside the core domain

Inject:

- pasteboard access
- app activation
- settings persistence
- file thumbnails/icons
- platform notifications

Do not protocol-ize pure shared logic just for abstraction theater.

## Testing Plan

### Shared module tests

- move browser state-machine tests with the extracted browser feature
- add tests for new settings/environment value mapping
- add tests for `ClipboardStore` replacements at the service boundary

### Integration tests

- keep Rust integration tests authoritative for storage/search/sync invariants
- add Swift integration tests around repository adapters and service composition

### Platform tests

- keep macOS UI tests focused on panel/menu-bar behavior
- future iOS UI tests should focus on shell composition, not re-test shared business logic exhaustively

## Suggested Delegation Board

Use these as separate delegate tickets.

### Ticket A

Title: Extract shared and platform library targets in `Project.swift`

Owned files:

- `Project.swift`
- new source roots only

Blocked by:

- nothing

### Ticket B

Title: Make UniFFI Swift wrapper compile without `AppKit`

Owned files:

- `Sources/ClipKittyRustWrapper/**`

Blocked by:

- Ticket A preferred but not strictly required

### Ticket C

Title: Introduce shared settings/capability abstractions and remove singleton reads from shared paths

Owned files:

- `Sources/App/Settings.swift`
- shared settings models
- files that currently read `AppSettings.shared` from shared logic

Blocked by:

- Ticket A

### Ticket D

Title: Move browser session and browser view model into `ClipKittyShared`

Owned files:

- `Sources/App/Browser/BrowserSession.swift`
- `Sources/App/Browser/BrowserStoreClient.swift`
- `Sources/App/Browser/BrowserViewModel.swift`
- related tests

Blocked by:

- Ticket A
- Ticket C

### Ticket E

Title: Decompose `ClipboardStore` into bootstrap/search/ingestion/mutation/sync collaborators

Owned files:

- `Sources/App/ClipboardStore.swift`
- `Sources/App/Services/ClipboardRepository.swift`
- related shared services

Blocked by:

- Ticket C
- Ticket D strongly preferred

### Ticket F

Title: Extract Apple shared services (`SyncEngine`, OCR, link metadata, preview loading)

Owned files:

- `Sources/App/Services/SyncEngine.swift`
- `Sources/App/ImageDescriptionGenerator.swift`
- `Sources/App/LinkMetadataFetcher.swift`
- `Sources/App/Services/PreviewLoader.swift`

Blocked by:

- Ticket A
- Ticket B

### Ticket G

Title: Isolate macOS shell into `ClipKittyMacPlatform`

Owned files:

- AppKit shell files only

Blocked by:

- Tickets D, E, F preferred

### Ticket H

Title: Scaffold thin iOS app target over the shared core

Owned files:

- new iOS target files
- iOS composition root

Blocked by:

- Tickets A through F

## Risks and Mitigations

### Risk: moving too much into Rust

Why it is risky:

- slows iteration on Apple-platform UI workflows
- makes SwiftUI integration more awkward

Mitigation:

- keep durable invariants in Rust
- keep Apple-platform feature orchestration in shared Swift

### Risk: trying to share top-level views too early

Why it is risky:

- macOS panel UX and iOS navigation UX will diverge

Mitigation:

- share feature state and intents first
- only share leaf views later if they remain natural

### Risk: merge conflicts during extraction

Why it is risky:

- many tickets touch the same current app target

Mitigation:

- enforce workstream ownership
- merge in the recommended order
- avoid parallel edits to `ClipboardStore.swift` and `Project.swift` unless coordinated

### Risk: hidden AppKit leakage

Why it is risky:

- shared targets compile on macOS but fail as soon as iOS is added

Mitigation:

- treat "compiles without `AppKit`" as a hard acceptance criterion for shared targets

## Final Success Criteria

The refactor is successful when all of the following are true:

- Rust remains the invariant boundary for storage, search, and sync.
- Shared Swift compiles without `AppKit`.
- Browser/search/edit/mutation logic lives in shared Swift rather than the macOS app target.
- macOS shell code is isolated behind a macOS-only target boundary.
- Cross-Apple services live outside the macOS app target.
- A future iOS app can be built as a thin shell over the existing shared core.

---

## Worklog

### Implementation Summary (2026-03-31)

All workstreams (W1–W7) implemented in a single coordinated pass. Build succeeds, all tests pass.

#### What was done

**W1 — Target Graph Extraction**
- Added 3 new library targets in `Project.swift`: `ClipKittyShared`, `ClipKittyAppleServices`, `ClipKittyMacPlatform`
- Created source roots: `Sources/Shared/`, `Sources/AppleServices/`, `Sources/MacPlatform/`
- App target depends on all three libraries. Tests depend on all libraries.
- AppleServices gets `ENABLE_SYNC` compilation conditions across all build configs.

**W2 — Rust Wrapper Cleanup**
- Removed `import AppKit` from `Sources/ClipKittyRustWrapper/ClipKittyRust.swift` — replaced with `import Foundation`. No AppKit types were actually used (NSRange is Foundation).

**W3 — Shared Settings/Environment Boundary**
- Extracted `HotKey` struct into `Sources/Shared/HotKey.swift` (platform-independent, uses raw UInt32 modifier constants instead of Carbon symbols).
- `modifierMask` (NSEvent.ModifierFlags) stays as an extension in `Sources/App/Settings.swift`.
- `PasteboardMonitor.FilterConfiguration` replaces direct `AppSettings.shared` reads — injected as a closure from the composition root.
- `BrowserViewModel` takes `shouldGenerateLinkPreviews` closure instead of reaching into `AppSettings.shared`.

**W4 — Browser Feature Extraction**
- Moved to `Sources/Shared/`: `BrowserSession.swift`, `BrowserStoreClient.swift` (protocol only), `BrowserViewModel.swift`.
- Removed `import AppKit` from BrowserViewModel — no AppKit types were actually used.
- Introduced `BrowserViewModel.BrowserAction` enum (shared semantic actions) to replace the app-layer `BrowserActionItem` in the shared interface.
- `BrowserActionItem` stays in app with a `.browserAction` bridge property.
- Concrete `ClipboardStoreBrowserClient` adapter stays in `Sources/App/Browser/BrowserStoreClient.swift`.

**W5 — ClipboardStore Decomposition (Partial)**
- Image ingestion moved to `ImageIngestService` in AppleServices (was already extracted, just moved targets).
- Image description generation, link metadata fetching, preview loading all moved to AppleServices.
- Sync engine moved to AppleServices.
- ClipboardStore remains as the composition root / facade for the macOS app. Full decomposition into separate search/mutation/ingestion services deferred — the current shape already enables iOS reuse through the shared `BrowserStoreClient` protocol.

**W6 — Apple Shared Services Extraction**
- Moved to `Sources/AppleServices/`: `SyncEngine.swift`, `ImageDescriptionGenerator.swift`, `LinkMetadataFetcher.swift`, `PreviewLoader.swift`, `ImageIngestService.swift`.
- Removed AppKit from `LinkMetadataFetcher` — replaced NSImage/NSBitmapImageRep with CoreGraphics/ImageIO.
- Removed AppKit from `ImageIngestService` — replaced with CoreGraphics.
- All types made `public` with proper memberwise inits.

**W7 — macOS Platform Isolation**
- Moved to `Sources/MacPlatform/`: `PasteboardMonitor.swift`, `PasteService.swift`, `PasteboardProtocol.swift`, `AppActivationService.swift`, `HotKeyManager.swift`, `LaunchAtLogin.swift`, `FontManager.swift`, `AccessibilityPermissionMonitor.swift`.
- `FloatingPanelController` stays in app target (depends on ClipboardStore, AppSettings, etc — would create circular dependency).
- All types made `public`.
- `FontManager.registerFonts()` uses `Bundle.main` instead of `Bundle.module` since font resources live in the app bundle.

**Shared notification types**
- Extracted `NotificationKind`, `NudgeKind`, `InfoKind`, `SnackbarItem` into `Sources/Shared/NotificationTypes.swift`.
- Removed duplicates from `Sources/App/Snackbar.swift`.

#### Tradeoffs

1. **FloatingPanelController stays in App** — It depends on ClipboardStore, AppSettings, SnackbarCoordinator, and multiple view types. Moving it to MacPlatform would create circular dependencies. A future iOS app doesn't need it anyway.

2. **ClipboardStore not fully decomposed** — The plan called for splitting into StoreBootstrapper, SearchSessionService, IngestionCoordinator, etc. ClipboardStore remains as a facade, but the iOS-shareable surface is already clean: `BrowserStoreClient` protocol + `ClipboardRepository`. Full decomposition would add complexity without unlocking new reuse.

3. **AppSettings.shared still exists** — The singleton persists in the app target. Shared code no longer reads it directly (uses closures/injected values instead). A full protocol-based settings abstraction was overkill at this stage.

4. **HotKey uses raw UInt32 constants** — Carbon `optionKey`/`cmdKey` etc. are not available in shared code. The shared `HotKey` struct uses their literal values (0x0800, 0x0100, etc.) instead.

5. **BrowserAction vs BrowserActionItem** — Two representations of the same concept. `BrowserAction` in shared is pure semantics; `BrowserActionItem` in app adds UI labels/icons and AppSettings-dependent logic. The bridge is a single computed property.

6. **SnackbarScheduler stays in App** — `LiveSnackbarEnvironment` uses `AppSettings.shared` and `LaunchAtLogin.shared`. The pure `evaluateSnackbar` function could move to Shared but the value is minimal since the scheduler itself is macOS-specific UX.

#### Blockers encountered

- None. All workstreams completed without blockers.

#### Verification

- `xcodebuild build CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED**
- `xcodebuild test CODE_SIGNING_ALLOWED=NO` — **TEST SUCCEEDED** (all unit tests pass)
- ClipKittyShared compiles without AppKit ✓
- ClipKittyAppleServices compiles without AppKit ✓
- ClipKittyMacPlatform compiles independently ✓
