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
DMG_SUFFIX := $(if $(filter true,$(SANDBOX)),-Sandboxed,)
DMG_NAME := $(APP_NAME)$(DMG_SUFFIX).dmg

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

.PHONY: all clean sign screenshot perf build-binary dmg appstore validate upload rust rust-force

# Signing identity: auto-detects Developer ID cert, falls back to ad-hoc (-)
# Override: make sign SIGNING_IDENTITY="Developer ID Application: ..."
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

# App Store signing identities (used only by `make appstore`)
APPSTORE_SIGNING_IDENTITY ?= 3rd Party Mac Developer Application
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

# Build DMG installer
dmg: all sign
	@echo "Building$(if $(filter true,$(SANDBOX)), sandboxed,) DMG installer..."
	@./Scripts/build-dmg.sh "$(APP_BUNDLE)" "$(DMG_NAME)"

# Screenshot launches the app with synthetic data and takes a fullscreen capture
screenshot: run-synthetic
	@echo "Preparing environment and taking screenshot..."
	@./Scripts/prepare-screenshot-environment.sh 'pkill ClipKitty || true && open ClipKitty.app --args --use-simulated-db && sleep 3 && screencapture screenshot.png && pkill ClipKitty || true'
	@if [ -f screenshot.png ]; then \
		WIDTH=$$(sips -g pixelWidth screenshot.png | tail -1 | awk '{print $$2}'); \
		HEIGHT=$$(sips -g pixelHeight screenshot.png | tail -1 | awk '{print $$2}'); \
		sips --resampleHeightWidth $$((HEIGHT * 2)) $$((WIDTH * 2)) screenshot.png --out screenshot.png; \
	fi
	@echo "Screenshot saved to screenshot.png (2x upscaled)"

# Export app icon as PNG (for README, gh-pages, etc.)
icon-png:
	@sips -s format png "$(SCRIPT_DIR)/AppIcon.icns" --out icon.png

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
	@codesign --force --options runtime \
		--sign "$(APPSTORE_SIGNING_IDENTITY)" \
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
#   make marketing-screenshots    # Generate App Store screenshots with captions
#   make preview-video            # Record App Store preview video
#   make marketing                # Generate all marketing assets
# ============================================================================



# Generate synthetic data for UI tests and marketing
# Requires GEMINI_API_KEY environment variable for AI-generated content
# Run Scripts/patch-demo-items.sh after to add demo-specific items
synthetic-data:
	@echo "Generating synthetic data..."
	@$(NIX_SHELL) "cd rust-data-gen && cargo run --release -- --db-path ../Sources/App/SyntheticData.sqlite"
	@echo "Synthetic data generated at Sources/App/SyntheticData.sqlite"
	@echo "Run ./Scripts/patch-demo-items.sh to add demo items"

# Open app with synthetic data for manual testing
# Uses non-sandboxed build for simpler file access
run-synthetic:
	@$(MAKE) sign SANDBOX=false
	@echo "Setting up synthetic data..."
	@mkdir -p ~/Library/Application\ Support/ClipKitty
	@rm -f ~/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite*
	@rm -rf ~/Library/Application\ Support/ClipKitty/tantivy_index
	@cp Sources/App/SyntheticData.sqlite ~/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite
	@echo "Launching app with synthetic data..."
	@open ClipKitty.app --args --use-simulated-db

.PHONY: marketing marketing-screenshots marketing-screenshots-capture preview-video print-background-image run-synthetic

# Print background image path (used by CI/scripts)
print-background-image:
	@echo $(BACKGROUND_IMAGE)

# Capture raw marketing screenshots via UI test (with clean environment, uses sandboxed)
# Requires full Xcode installation
marketing-screenshots-capture:
ifeq ($(HAVE_XCODE),false)
	$(error Xcode is required for marketing screenshots. Install Xcode from the App Store.)
endif
	@./Scripts/patch-demo-items.sh
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
# Requires full Xcode installation
preview-video:
ifeq ($(HAVE_XCODE),false)
	$(error Xcode is required for preview video. Install Xcode from the App Store.)
endif
	@./Scripts/patch-demo-items.sh
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
