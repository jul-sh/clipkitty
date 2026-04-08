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

# Build configuration: Debug, Release (DMG), or AppStore (sandboxed)
CONFIGURATION ?= Release

# DerivedData location for deterministic output paths
DERIVED_DATA := $(SCRIPT_DIR)/DerivedData

# Signing identity: auto-detects Developer ID cert, falls back to ad-hoc (-)
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

# Rust build marker and outputs
RUST_MARKER := .make/rust.marker
RUST_LIB := Sources/ClipKittyRust/libpurr.a

.PHONY: all clean rust rust-force generate build signing api-key provisioning provisioning-secrets sign list-identities run run-perf test unittest uitest rust-test perf-test perf-db perf-bench

all: rust generate build

# Marker-based Rust build - uses git tree hash for change detection
# This marker is shared with Xcode pre-build actions for consistency
$(RUST_MARKER): $(shell git ls-files purr 2>/dev/null)
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 UNIVERSAL=$(UNIVERSAL) cargo run --release --bin generate-bindings"
	@mkdir -p .make
	@touch $(RUST_MARKER)
	@git rev-parse HEAD:purr > .make/rust-tree-hash 2>/dev/null || true

# Also rebuild if the output library is missing
rust: $(RUST_MARKER)
	@test -f $(RUST_LIB) || (rm -f $(RUST_MARKER) && $(MAKE) $(RUST_MARKER))

# Force rebuild Rust (ignore marker)
rust-force:
	@rm -f $(RUST_MARKER)
	@$(MAKE) rust

# Resolve dependencies and generate Xcode project from Tuist manifest
generate:
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
	@$(NIX_SHELL) "cd purr && cargo test"

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
	@$(NIX_SHELL) "cd purr && cargo run --release --bin generate-perf-db"

# Run the maintained Rust search benchmark runner
# Usage: make perf-bench [BENCH_ARGS="--iterations 20 --warmup 5 --query function"]
perf-bench: perf-db
	@echo "Running search benchmark..."
	@$(NIX_SHELL) "cd purr && cargo run --release --bin run_search_bench -- $(BENCH_ARGS)"

# Run performance tests with Instruments tracing
# Usage: make perf-test [PERF_ARGS="--skip-build --fail-on-hangs"]
perf-test: all perf-db
	@echo "Running performance tests with tracing..."
	@./Scripts/run-perf-test.sh --skip-build $(PERF_ARGS)
