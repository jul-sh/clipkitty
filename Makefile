#      (\_/)
#      (o.o)
#      / > [nix-shell]  <-- for Rust commands

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := ./Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Version: override via `make all VERSION=1.2.3`
# BUILD_NUMBER defaults to VERSION so CFBundleVersion matches sparkle:version in the appcast.
# App Store CI overrides BUILD_NUMBER explicitly with an integer commit count.
VERSION ?= 1.0.0
BUILD_NUMBER ?= $(VERSION)

# Build configuration: Debug, Release (DMG), SparkleRelease, AppStore (sandboxed), or Hardened
CONFIGURATION ?= Release

# Pass LOCKED=1 in CI to enforce Cargo.lock (adds --locked to cargo commands)
CARGO_LOCKED := $(if $(filter 1,$(LOCKED)),--locked,)
export LOCKED

# DerivedData location for deterministic output paths
DERIVED_DATA := $(SCRIPT_DIR)/DerivedData

# Signing identity: auto-detects Developer ID cert, falls back to ad-hoc (-)
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

# Shared Rust target dir — always resolves to main worktree's target/.
# Safe to share: cargo tracks source hashes internally, so switching between
# worktrees with different Rust code triggers a rebuild of changed crates
# while reusing unchanged dependencies.
CARGO_TARGET_DIR := $(dir $(abspath $(shell git rev-parse --git-common-dir 2>/dev/null)))target
export CARGO_TARGET_DIR

# Rust build marker and outputs
# Separate markers for universal vs host-only builds so switching UNIVERSAL
# correctly triggers a rebuild instead of reusing a mismatched libpurr.a.
ifeq ($(UNIVERSAL),1)
RUST_MARKER := .make/rust-universal.marker
RUST_STALE_MARKER := .make/rust.marker
else
RUST_MARKER := .make/rust.marker
RUST_STALE_MARKER := .make/rust-universal.marker
endif
RUST_LIB := Sources/ClipKittyRust/libpurr.a

.PHONY: all clean rust rust-force rust-cache-clean rust-cache-maybe-clean generate build signing api-key provisioning provisioning-secrets sign list-identities run run-perf test unittest uitest rust-test perf-test perf-db perf-bench

all: rust generate build

# Marker-based Rust build - uses git tree hash for change detection
# This marker is shared with Xcode pre-build actions for consistency
$(RUST_MARKER): $(shell git ls-files purr 2>/dev/null)
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 UNIVERSAL=$(UNIVERSAL) cargo run $(CARGO_LOCKED) --release --bin generate-bindings"
	@mkdir -p .make
	@rm -f $(RUST_STALE_MARKER)
	@touch $(RUST_MARKER)
	@git rev-parse HEAD:purr > .make/rust-tree-hash 2>/dev/null || true

# Also rebuild if the output library is missing
rust: $(RUST_MARKER) rust-cache-maybe-clean
	@test -f $(RUST_LIB) || (rm -f $(RUST_MARKER) && $(MAKE) $(RUST_MARKER))

# Force rebuild Rust (ignore marker)
rust-force:
	@rm -f $(RUST_MARKER)
	@$(MAKE) rust

# Resolve dependencies and generate Xcode project from Tuist manifest
generate:
	@rm -rf Tuist/.build/tuist-derived
	@echo "Resolving dependencies..."
	@tuist install
	@echo "Generating Xcode project..."
	@tuist generate --no-open

# Ensure signing certificates are available in keychain
signing:
	@./distribution/setup-dev-signing.sh

# Decrypt App Store Connect API key for automatic provisioning
API_KEY_DIR := $(SCRIPT_DIR)/.make/keys
api-key:
	@mkdir -p $(API_KEY_DIR)
	@if [ ! -f "$(API_KEY_DIR)/AuthKey.p8" ]; then \
		echo "Decrypting API key for provisioning..."; \
		./distribution/asc-auth.sh private-key-b64 | base64 --decode > "$(API_KEY_DIR)/AuthKey.p8"; \
	fi

# Ensure Mac Development provisioning profile is installed
provisioning: api-key
	@./distribution/setup-dev-provisioning.sh

# Refresh the encrypted provisioning profile secrets from App Store Connect.
provisioning-secrets:
	@./distribution/regenerate-provisioning-secrets.sh

# Build using xcodebuild with automatic signing
# CI sets SKIP_SIGNING=1 because ephemeral runners can't register devices
# for provisioning profiles. CI re-signs for distribution after building.
build: api-key
	@echo "Building $(APP_NAME) ($(CONFIGURATION))..."
	@xcodebuild -workspace $(APP_NAME).xcworkspace \
		-scheme $(APP_NAME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates \
		-authenticationKeyPath $(API_KEY_DIR)/AuthKey.p8 \
		-authenticationKeyID $$($(SCRIPT_DIR)/distribution/asc-auth.sh key-id) \
		-authenticationKeyIssuerID $$($(SCRIPT_DIR)/distribution/asc-auth.sh issuer-id) \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		ONLY_ACTIVE_ARCH=$(if $(UNIVERSAL),NO,YES) \
		$(if $(SKIP_SIGNING),CODE_SIGNING_ALLOWED=NO,) \
		build

# Sign the built app (for distribution)
sign:
	@echo "Signing $(APP_NAME) (identity: $(SIGNING_IDENTITY), config: $(CONFIGURATION))..."
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		"$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app"

# Build, kill any running instance, and open the app (uses Debug for development signing).
run: CONFIGURATION := Debug
run: all
	@echo "Closing existing $(APP_NAME)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@echo "Opening $(APP_NAME)..."
	@open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app"

# Run the app against the generated synthetic performance fixture
BUNDLE_ID := com.eviljuliette.clipkitty
APP_SUPPORT := $(HOME)/Library/Containers/$(BUNDLE_ID)/Data/Library/Application Support/ClipKitty
PERF_FIXTURE_DIR := purr/generated/benchmarks
PERF_DB := $(PERF_FIXTURE_DIR)/synthetic_clipboard.sqlite

run-perf: all perf-db
	@echo "Closing existing $(APP_NAME)..."
	@pkill -9 $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@echo "Setting up perf test database and index..."
	@mkdir -p "$(APP_SUPPORT)"
	@rm -f "$(APP_SUPPORT)/clipboard-screenshot.sqlite"*
	@rm -rf "$(APP_SUPPORT)"/tantivy_index_*
	@cp "$(PERF_DB)" "$(APP_SUPPORT)/clipboard-screenshot.sqlite"
	@cp -r $(PERF_FIXTURE_DIR)/tantivy_index_* "$(APP_SUPPORT)/"
	@echo "Opening $(APP_NAME) with perf database..."
	@open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app" --args --use-simulated-db

clean:
	@rm -rf .make DerivedData
	@tuist clean 2>/dev/null || true

# Remove Rust build artifacts not accessed in 30+ days from the shared cache.
# Runs automatically during rust builds at most once per week.
RUST_CACHE_SENTINEL := $(CARGO_TARGET_DIR)/.last-cache-clean

rust-cache-clean:
	@for d in purr/target .git/cargo-target; do \
		if [ -d "$$d" ]; then \
			echo "Removing legacy $$d (now using shared $(CARGO_TARGET_DIR))..."; \
			rm -rf "$$d"; \
		fi; \
	done
	@if [ -d "$(CARGO_TARGET_DIR)" ]; then \
		echo "Cleaning Rust cache (files unused for 30+ days)..."; \
		find "$(CARGO_TARGET_DIR)" -type f -atime +30 -not -name .last-cache-clean -delete; \
		find "$(CARGO_TARGET_DIR)" -type d -empty -delete; \
	fi
	@mkdir -p "$(CARGO_TARGET_DIR)"
	@touch "$(RUST_CACHE_SENTINEL)"

# Auto-clean if sentinel is older than 7 days (or missing)
rust-cache-maybe-clean:
	@if [ ! -f "$(RUST_CACHE_SENTINEL)" ] || \
	    [ -n "$$(find "$(RUST_CACHE_SENTINEL)" -mtime +7 2>/dev/null)" ]; then \
		$(MAKE) rust-cache-clean; \
	fi

# Run UI tests
# Usage: make uitest [TEST=testName]
# Example: make uitest TEST=testToastAppearsOnCopy
uitest: all
	@echo "Ensuring Git LFS files are pulled..."
	@git lfs pull 2>/dev/null || echo "Warning: git lfs pull failed (LFS not installed?)"
	@echo "Setting up signing keychain..."
	@./distribution/setup-dev-signing.sh
	@echo "Running UI tests..."
	@if [ -n "$(TEST)" ]; then \
		xcodebuild test -workspace $(APP_NAME).xcworkspace \
			-scheme ClipKittyUITests \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			-only-testing:ClipKittyUITests/ClipKittyUITests/$(TEST) \
			2>&1 | grep -E "(Test Case|passed|failed|error:)" || true; \
	else \
		xcodebuild test -workspace $(APP_NAME).xcworkspace \
			-scheme ClipKittyUITests \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			2>&1 | grep -E "(Test Case|passed|failed|error:)" || true; \
	fi

# Run all tests (Rust + Swift unit + UI)
test: rust-test unittest uitest

# Run Rust tests
rust-test:
	@echo "Running Rust tests..."
	@$(NIX_SHELL) "cd purr && cargo test $(CARGO_LOCKED)"

# Run Swift unit tests (requires workspace for STTextKitPlus dependency)
# Usage: make unittest [TEST=testName]
# Example: make unittest TEST=testNsRangeWithEmoji
unittest: rust generate
	@echo "Running Swift unit tests..."
	@if [ -n "$(TEST)" ]; then \
		xcodebuild test -workspace $(APP_NAME).xcworkspace \
			-scheme $(APP_NAME) \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			-only-testing:ClipKittyTests/$(TEST) \
			2>&1 | grep -E "(Test Case|Test Suite|passed|failed|error:|warning:)" || true; \
	else \
		xcodebuild test -workspace $(APP_NAME).xcworkspace \
			-scheme $(APP_NAME) \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			-only-testing:ClipKittyTests \
			2>&1 | grep -E "(Test Case|Test Suite|passed|failed|error:|warning:)" || true; \
	fi

# Show available signing identities (helpful for setup)
list-identities:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning | grep -E "(Developer|3rd Party)"
	@echo ""
	@echo "Set SIGNING_IDENTITY in your environment or pass to make:"
	@echo "  make sign SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""

# Generate the synthetic benchmark database and matching index
perf-db:
	@echo "Generating performance test database..."
	@$(NIX_SHELL) "cd purr && cargo run $(CARGO_LOCKED) --release --bin generate-perf-db"

# Run the maintained Rust search benchmark runner
# Usage: make perf-bench [BENCH_ARGS="--iterations 20 --warmup 5 --query function"]
perf-bench: perf-db
	@echo "Running search benchmark..."
	@$(NIX_SHELL) "cd purr && cargo run $(CARGO_LOCKED) --release --bin run_search_bench -- $(BENCH_ARGS)"

# Run performance tests with Instruments tracing
# Usage: make perf-test [PERF_ARGS="--skip-build --fail-on-hangs"]
perf-test: all perf-db
	@echo "Running performance tests with tracing..."
	@./Scripts/run-perf-test.sh --skip-build $(PERF_ARGS)
