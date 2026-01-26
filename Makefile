#      (\_/)
#      (o.o)
#      / > [nix-shell]  <-- for Rust commands

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := ./Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
BUNDLE_ID := com.clipkitty.app
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ICON_SOURCE := $(SCRIPT_DIR)/AppIcon.icon
ARCHS ?= arm64 x86_64
SWIFT_ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))

# Sandboxing control (default true)
SANDBOX ?= true

# The core app bundle components (bundle name is always the same)
APP_BUNDLE := $(APP_NAME).app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_PLIST := $(APP_BUNDLE)/Contents/Info.plist
APP_ICONS := $(APP_BUNDLE)/Contents/Resources/Assets.car
ENTITLEMENTS := $(if $(filter true,$(SANDBOX)),Sources/App/ClipKitty-Sandboxed.entitlements,Sources/App/ClipKitty.entitlements)
DMG_SUFFIX := $(if $(filter true,$(SANDBOX)),-Sandboxed,)
DMG_NAME := $(APP_NAME)$(DMG_SUFFIX).dmg

# Rust build marker and outputs
RUST_MARKER := .make/rust.marker
RUST_LIB := Sources/ClipKittyRust/libclipkitty_core.a

# Common Swift build command
SWIFT_SANDBOX_FLAG := $(if $(filter true,$(SANDBOX)),-Xswiftc -DSANDBOXED,)
SWIFT_BUILD := GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release $(SWIFT_ARCH_FLAGS) $(SWIFT_SANDBOX_FLAG)

# Icon compilation helper (usage: $(call compile-icons,destination-dir))
define compile-icons
xcrun actool "$(ICON_SOURCE)" --compile $(1) --platform macosx --target-device mac \
	--minimum-deployment-target 15.0 --app-icon AppIcon --include-all-app-icons \
	--output-partial-info-plist /dev/null
endef

.PHONY: all clean sign screenshot perf build-binary dmg appstore validate upload rust rust-force

# App Store signing identity (find yours with: security find-identity -v -p codesigning)
# Set via environment or override: make appstore SIGNING_IDENTITY="Developer ID Application: ..."
SIGNING_IDENTITY ?= 3rd Party Mac Developer Application
INSTALLER_IDENTITY ?= 3rd Party Mac Developer Installer

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

# Compile icons
$(APP_ICONS): $(ICON_SOURCE)
	@echo "Compiling icons..."
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@$(call compile-icons,"$(APP_BUNDLE)/Contents/Resources")

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
	@echo "Signing with $(if $(filter true,$(SANDBOX)),sandboxed,standard) entitlements..."
	@codesign --force --deep --sign - --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"

# Perf runs without icons and only runs perf tests (uses non-sandboxed for UI testing)
perf:
	@$(MAKE) sign SANDBOX=false
	@$(MAKE) ClipKitty.xcodeproj
	@echo "Running UI Performance Tests..."
	@rm -rf DerivedData
	@xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyPerformanceTests | tee xcodebuild.log
	@swift Scripts/PrintPerfResults.swift

# Build DMG installer
dmg: all sign
	@echo "Building$(if $(filter true,$(SANDBOX)), sandboxed,) DMG installer..."
	@./Scripts/build-dmg.sh "$(APP_BUNDLE)" "$(DMG_NAME)"

# Screenshot runs everything (uses non-sandboxed for UI testing)
screenshot:
	@$(MAKE) sign SANDBOX=false
	@$(MAKE) ClipKitty.xcodeproj
	@echo "Running UI Tests..."
	@rm -rf DerivedData
	@./Scripts/prepare-screenshot-environment.sh 'xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination "platform=macOS" -derivedDataPath DerivedData 2>&1 | tee xcodebuild.log'
	@swift Scripts/PrintPerfResults.swift
	@echo "Copying and upscaling screenshot..."
	@cp /tmp/clipkitty_screenshot.png screenshot.png || true
	@if [ -f screenshot.png ]; then \
		WIDTH=$$(sips -g pixelWidth screenshot.png | tail -1 | awk '{print $$2}'); \
		HEIGHT=$$(sips -g pixelHeight screenshot.png | tail -1 | awk '{print $$2}'); \
		sips --resampleHeightWidth $$((HEIGHT * 2)) $$((WIDTH * 2)) screenshot.png --out screenshot.png; \
	fi
	@echo "Screenshot saved to screenshot.png (2x upscaled)"

# Export app icon as PNG (for README, gh-pages, etc.)
icon-png:
	@rm -rf .icon-build && mkdir -p .icon-build
	@$(call compile-icons,.icon-build)
	@sips -s format png .icon-build/AppIcon.icns --out icon.png
	@rm -rf .icon-build
	@echo "Icon saved to icon.png"

# ============================================================================
# App Store Submission
# ============================================================================
# Prerequisites:
#   1. Apple Developer account with Mac App Store distribution
#   2. App-specific password for notarytool (store in keychain):
#      xcrun notarytool store-credentials "ClipKitty-AppStore" \
#        --apple-id "your@email.com" --team-id "TEAMID" --password "app-specific-password"
#   3. Provisioning profile installed (~/Library/MobileDevice/Provisioning Profiles/)
#   4. Certificates installed in Keychain:
#      - "3rd Party Mac Developer Application: Your Name (TEAMID)"
#      - "3rd Party Mac Developer Installer: Your Name (TEAMID)"
#
# Usage:
#   make appstore                    # Build, sign, package for App Store
#   make validate                    # Validate the package with App Store Connect
#   make upload                      # Upload to App Store Connect
#   make appstore-all                # Build, validate, and upload in one step
# ============================================================================

# Build and sign for App Store (always uses sandboxed)
appstore:
	@$(MAKE) all SANDBOX=true
	@echo "Re-signing for App Store distribution..."
	@codesign --force --deep --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements Sources/App/ClipKitty-Sandboxed.entitlements \
		"$(APP_BUNDLE)"
	@echo "Creating installer package..."
	@rm -f "$(APP_NAME).pkg"
	@productbuild --component "$(APP_BUNDLE)" /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		"$(APP_NAME).pkg"
	@echo "App Store package created: $(APP_NAME).pkg"

# Validate the package with App Store Connect
validate: $(APP_NAME).pkg
	@echo "Validating with App Store Connect..."
	@xcrun altool --validate-app -f "$(APP_NAME).pkg" -t macos \
		--apiKey "$(APPSTORE_API_KEY)" --apiIssuer "$(APPSTORE_API_ISSUER)"

# Upload to App Store Connect
upload: $(APP_NAME).pkg
	@echo "Uploading to App Store Connect..."
	@xcrun altool --upload-app -f "$(APP_NAME).pkg" -t macos \
		--apiKey "$(APPSTORE_API_KEY)" --apiIssuer "$(APPSTORE_API_ISSUER)"
	@echo "Upload complete! Check App Store Connect for processing status."

# All-in-one: build, validate, upload
appstore-all: appstore validate upload

# Show available signing identities (helpful for setup)
list-identities:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning | grep -E "(Developer|3rd Party)"
	@echo ""
	@echo "Set SIGNING_IDENTITY and INSTALLER_IDENTITY in your environment or pass to make:"
	@echo "  make appstore SIGNING_IDENTITY=\"3rd Party Mac Developer Application: Your Name (TEAMID)\""

# ============================================================================
# Marketing Assets (Screenshots & Preview Video)
# ============================================================================
# Prerequisites:
#   1. ImageMagick (full): brew install imagemagick-full (required for font rendering)
#   2. ffmpeg: brew install ffmpeg
#   3. Synthetic data with demo items: make synthetic-data
#
# Configuration
BACKGROUND_IMAGE := /System/Library/Desktop Pictures/Solid Colors/Silver.png
#
# Usage:
#   make synthetic-data           # Generate synthetic data with demo items
#   make marketing-screenshots    # Generate App Store screenshots with captions
#   make preview-video            # Record App Store preview video
#   make marketing                # Generate all marketing assets
# ============================================================================

# Generate synthetic data with demo items for UI tests and marketing
# Requires GEMINI_API_KEY environment variable for AI-generated content
synthetic-data:
	@echo "Generating synthetic data with demo items..."
	@$(NIX_SHELL) "cd rust-core && cargo run --release --features data-gen --bin generate_synthetic_data -- --demo --db-path ../Sources/App/SyntheticData.sqlite"
	@echo "Synthetic data generated at Sources/App/SyntheticData.sqlite"

.PHONY: marketing marketing-screenshots marketing-screenshots-capture preview-video print-background-image synthetic-data

# Print background image path (used by CI/scripts)
print-background-image:
	@echo $(BACKGROUND_IMAGE)

# Capture raw marketing screenshots via UI test (with clean environment, uses sandboxed)
marketing-screenshots-capture:
	@$(MAKE) sign SANDBOX=true
	@$(MAKE) ClipKitty.xcodeproj
	@echo "Capturing marketing screenshots..."
	@rm -rf DerivedData
	@./Scripts/prepare-screenshot-environment.sh 'xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination "platform=macOS" -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots 2>&1 | grep -E "(Test Case|passed|failed)" || true'
	@echo "Raw screenshots saved to /tmp/clipkitty_marketing_*.png"

# Process raw screenshots into marketing-ready images
marketing-screenshots-process:
	@echo "Processing screenshots..."
	@BACKGROUND_IMAGE="$(BACKGROUND_IMAGE)" ./Scripts/generate-marketing-screenshots.sh

# Full screenshot pipeline: capture + process
marketing-screenshots: marketing-screenshots-capture marketing-screenshots-process
	@echo "Marketing screenshots complete! See marketing/ directory"

# Record App Store preview video (uses sandboxed)
preview-video:
	@$(MAKE) sign SANDBOX=true
	@$(MAKE) ClipKitty.xcodeproj
	@echo "Recording preview video..."
	@./Scripts/record-preview-video.sh

# Generate all marketing assets
marketing: marketing-screenshots preview-video
	@echo ""
	@echo "=== All Marketing Assets Generated ==="
	@echo "Screenshots: marketing/screenshot_*.png"
	@echo "Video: marketing/app_preview.mov"
	@ls -lh marketing/ 2>/dev/null || true
