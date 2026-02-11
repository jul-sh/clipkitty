#      (\_/)
#      (o.o)
#      / > [nix-shell]  <-- for Rust commands

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := ./Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
BUNDLE_ID := com.clipkitty.app
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ICON_SOURCE := $(SCRIPT_DIR)/AppIcon.icon

# Detect Xcode availability (required for UI tests, marketing assets, universal binaries)
HAVE_XCODE := $(shell xcodebuild -version >/dev/null 2>&1 && echo true || echo false)

# Universal binaries require Xcode; without it, build for native arch only
ifeq ($(HAVE_XCODE),true)
ARCHS ?= arm64 x86_64
else
ARCHS ?= $(shell uname -m)
endif
SWIFT_ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))

# Sandboxing control (default true)
SANDBOX ?= true

# The core app bundle components (bundle name is always the same)
APP_BUNDLE := $(APP_NAME).app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_PLIST := $(APP_BUNDLE)/Contents/Info.plist
APP_ICONS := $(APP_BUNDLE)/Contents/Resources/Assets.car
ENTITLEMENTS := $(if $(filter true,$(SANDBOX)),Sources/App/ClipKitty-Sandboxed.entitlements,Sources/App/ClipKitty.entitlements)

# Rust build marker and outputs
RUST_MARKER := .make/rust.marker
RUST_LIB := Sources/ClipKittyRust/libclipkitty_core.a

# Common Swift build command
SWIFT_SANDBOX_FLAG := $(if $(filter true,$(SANDBOX)),-Xswiftc -DSANDBOXED,)
SWIFT_BUILD := GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release --build-system native $(SWIFT_ARCH_FLAGS) $(SWIFT_SANDBOX_FLAG)

# Icon handling - compile with actool if Xcode available, otherwise use pre-compiled .icns
ifeq ($(HAVE_XCODE),true)
define setup-icons
xcrun actool "$(ICON_SOURCE)" --compile $(1) --platform macosx --target-device mac \
	--minimum-deployment-target 15.0 --app-icon AppIcon --include-all-app-icons \
	--output-partial-info-plist /dev/null
endef
else
define setup-icons
cp "$(SCRIPT_DIR)/AppIcon.icns" $(1)/AppIcon.icns
endef
endif

.PHONY: all clean sign build-binary rust rust-force list-identities

# Signing identity: auto-detects Developer ID cert, falls back to ad-hoc (-)
# Override: make sign SIGNING_IDENTITY="Developer ID Application: ..."
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

all: $(APP_BUNDLE)

# Marker-based Rust build - only rebuilds if sources changed
# Uses git ls-files to get all tracked files in rust-core (respects .gitignore)
$(RUST_MARKER): $(shell git ls-files rust-core 2>/dev/null)
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd rust-core && cargo run --release --bin generate-bindings"
	@mkdir -p .make
	@touch $(RUST_MARKER)

# Also rebuild if the output library is missing
rust: $(RUST_MARKER)
	@test -f $(RUST_LIB) || (rm -f $(RUST_MARKER) && $(MAKE) $(RUST_MARKER))

# Force rebuild Rust (ignore marker)
rust-force:
	@rm -f $(RUST_MARKER)
	@$(MAKE) rust

# Build just the binary using SwiftPM
build-binary: rust
	@echo "Building binary (SANDBOX=$(SANDBOX))..."
	@$(SWIFT_BUILD)

# Create the bundle structure and copy the binary
$(APP_BINARY): build-binary
	@echo "Creating app bundle structure..."
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@BIN=$$($(SWIFT_BUILD) --show-bin-path); \
		cp "$$BIN/$(APP_NAME)" "$(APP_BINARY)"; \
		test -d "$$BIN/$(APP_NAME)_$(APP_NAME).bundle" && \
		cp -R "$$BIN/$(APP_NAME)_$(APP_NAME).bundle" "$(APP_BUNDLE)/Contents/Resources/" || true
	@cp "Sources/App/PrivacyInfo.xcprivacy" "$(APP_BUNDLE)/Contents/Resources/"


# Generate Info.plist
$(APP_PLIST):
	@echo "Generating Info.plist..."
	@mkdir -p "$(APP_BUNDLE)/Contents"
	@swift Scripts/GenInfoPlist.swift "$(APP_PLIST)"
	@touch "$(APP_BUNDLE)"

# Setup icons (compile or copy depending on Xcode availability)
$(APP_ICONS): $(ICON_SOURCE)
	@echo "Setting up icons..."
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@$(call setup-icons,"$(APP_BUNDLE)/Contents/Resources")

# Minimal app bundle for tests
$(APP_BUNDLE): $(APP_BINARY) $(APP_PLIST) $(APP_ICONS)
	@touch "$(APP_BUNDLE)"

# Xcode project generation
ClipKitty.xcodeproj: Scripts/GenXcodeproj.swift $(wildcard Tests/UITests/*.swift)
	@echo "Generating Xcode project..."
	@swift Scripts/GenXcodeproj.swift

clean:
	@git stash push --quiet
	@git clean -fdx
	@git stash pop --quiet || true
	@rm -rf .make

sign: $(APP_BUNDLE)
	@echo "Signing with $(if $(filter true,$(SANDBOX)),sandboxed,standard) entitlements (identity: $(SIGNING_IDENTITY))..."
	@codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"

# Show available signing identities (helpful for setup)
list-identities:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning | grep -E "(Developer|3rd Party)"
	@echo ""
	@echo "Set SIGNING_IDENTITY in your environment or pass to make:"
	@echo "  make sign SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
