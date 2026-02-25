#      (\_/)
#      (o.o)
#      / > [nix-shell]  <-- for Rust commands

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := ./Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Version: override via `make all VERSION=1.2.3 BUILD_NUMBER=42`
VERSION ?= 1.0.0
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# Build configuration: Debug, Release (DMG), or AppStore (sandboxed)
CONFIGURATION ?= Release

# DerivedData location for deterministic output paths
DERIVED_DATA := $(SCRIPT_DIR)/DerivedData

# Signing identity: auto-detects Developer ID cert, falls back to ad-hoc (-)
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

# Rust build marker and outputs
RUST_MARKER := .make/rust.marker
RUST_LIB := Sources/ClipKittyRust/libpurr.a

.PHONY: all clean rust rust-force generate build sign list-identities run test uitest rust-test

all: rust generate build

# Marker-based Rust build - only rebuilds if sources changed
# Uses git ls-files to get all tracked files in purr (respects .gitignore)
$(RUST_MARKER): $(shell git ls-files purr 2>/dev/null)
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd purr && cargo run --release --bin generate-bindings"
	@mkdir -p .make
	@touch $(RUST_MARKER)

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

# Build using xcodebuild
build:
	@echo "Building $(APP_NAME) ($(CONFIGURATION))..."
	@xcodebuild -scheme $(APP_NAME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		build

# Sign the built app (for distribution)
sign:
	@echo "Signing $(APP_NAME) (identity: $(SIGNING_IDENTITY), config: $(CONFIGURATION))..."
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		"$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app"

# Build, kill any running instance, and open the app
run: all
	@echo "Closing existing $(APP_NAME)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@echo "Opening $(APP_NAME)..."
	@open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app"

clean:
	@rm -rf .make DerivedData
	@tuist clean 2>/dev/null || true

# Run UI tests
# Usage: make uitest [TEST=testName]
# Example: make uitest TEST=testToastAppearsOnCopy
uitest: all
	@echo "Setting up signing keychain..."
	@./distribution/setup-dev-signing.sh
	@echo "Running UI tests..."
	@if [ -n "$(TEST)" ]; then \
		xcodebuild test -scheme ClipKittyUITests \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			-only-testing:ClipKittyUITests/ClipKittyUITests/$(TEST) \
			2>&1 | grep -E "(Test Case|passed|failed|error:)" || true; \
	else \
		xcodebuild test -scheme ClipKittyUITests \
			-destination "platform=macOS" \
			-derivedDataPath $(DERIVED_DATA) \
			2>&1 | grep -E "(Test Case|passed|failed|error:)" || true; \
	fi

# Run all tests (Rust + UI)
test: rust-test uitest

# Run Rust tests
rust-test:
	@echo "Running Rust tests..."
	@$(NIX_SHELL) "cd purr && cargo test"

# Show available signing identities (helpful for setup)
list-identities:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning | grep -E "(Developer|3rd Party)"
	@echo ""
	@echo "Set SIGNING_IDENTITY in your environment or pass to make:"
	@echo "  make sign SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
