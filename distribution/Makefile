#      (\_/)
#      (o.o)
#      / > Distribution, marketing & release targets

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
DIST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := $(PROJECT_ROOT)/Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
APP_BUNDLE := $(APP_NAME).app
DMG_NAME = $(APP_NAME)$(if $(filter true,$(SANDBOX)),-Sandboxed,).dmg

# Detect Xcode availability (required for UI tests, marketing assets)
HAVE_XCODE := $(shell xcodebuild -version >/dev/null 2>&1 && echo true || echo false)

# Sandboxing control (default true)
SANDBOX ?= true

# Signing identities
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")
APPSTORE_SIGNING_IDENTITY ?= 3rd Party Mac Developer Application
INSTALLER_IDENTITY ?= 3rd Party Mac Developer Installer

# Marketing configuration
BACKGROUND_IMAGE := /System/Library/Desktop Pictures/Solid Colors/Silver.png

.PHONY: dmg appstore validate upload appstore-all screenshot icon-png \
        synthetic-data run-synthetic marketing marketing-screenshots \
        marketing-screenshots-capture marketing-screenshots-process \
        preview-video print-background-image

# Build DMG installer
dmg:
	@$(MAKE) -C $(PROJECT_ROOT) all sign SANDBOX=$(SANDBOX)
	@echo "Building$(if $(filter true,$(SANDBOX)), sandboxed,) DMG installer..."
	@$(DIST_DIR)/build-dmg.sh "$(PROJECT_ROOT)/$(APP_BUNDLE)" "$(PROJECT_ROOT)/$(DMG_NAME)"

# Screenshot launches the app with synthetic data and takes a fullscreen capture
screenshot: run-synthetic
	@echo "Preparing environment and taking screenshot..."
	@$(DIST_DIR)/prepare-screenshot-environment.sh 'cd $(PROJECT_ROOT) && pkill ClipKitty || true && open ClipKitty.app --args --use-simulated-db && sleep 3 && screencapture screenshot.png && pkill ClipKitty || true'
	@if [ -f $(PROJECT_ROOT)/screenshot.png ]; then \
		WIDTH=$$(sips -g pixelWidth $(PROJECT_ROOT)/screenshot.png | tail -1 | awk '{print $$2}'); \
		HEIGHT=$$(sips -g pixelHeight $(PROJECT_ROOT)/screenshot.png | tail -1 | awk '{print $$2}'); \
		sips --resampleHeightWidth $$((HEIGHT * 2)) $$((WIDTH * 2)) $(PROJECT_ROOT)/screenshot.png --out $(PROJECT_ROOT)/screenshot.png; \
	fi
	@echo "Screenshot saved to screenshot.png (2x upscaled)"

# Export app icon as PNG (for README, gh-pages, etc.)
icon-png:
	@sips -s format png "$(PROJECT_ROOT)/AppIcon.icns" --out $(PROJECT_ROOT)/icon.png

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
#   make -C distribution appstore            # Build, sign, package for App Store
#   make -C distribution validate            # Validate the package with App Store Connect
#   make -C distribution upload              # Upload to App Store Connect
#   make -C distribution appstore-all        # Build, validate, and upload in one step
# ============================================================================

# Build and sign for App Store (always uses sandboxed)
appstore:
	@$(MAKE) -C $(PROJECT_ROOT) all SANDBOX=true
	@echo "Re-signing for App Store distribution..."
	@codesign --force --options runtime \
		--sign "$(APPSTORE_SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty-Sandboxed.entitlements \
		"$(PROJECT_ROOT)/$(APP_BUNDLE)"
	@echo "Creating installer package..."
	@rm -f "$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@productbuild --component "$(PROJECT_ROOT)/$(APP_BUNDLE)" /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		"$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@echo "App Store package created: $(APP_NAME).pkg"

# Validate the package with App Store Connect
validate: $(PROJECT_ROOT)/$(APP_NAME).pkg
	@echo "Validating with App Store Connect..."
	@xcrun altool --validate-app -f "$(PROJECT_ROOT)/$(APP_NAME).pkg" -t macos \
		--apiKey "$(APPSTORE_API_KEY)" --apiIssuer "$(APPSTORE_API_ISSUER)"

# Upload to App Store Connect
upload: $(PROJECT_ROOT)/$(APP_NAME).pkg
	@echo "Uploading to App Store Connect..."
	@xcrun altool --upload-app -f "$(PROJECT_ROOT)/$(APP_NAME).pkg" -t macos \
		--apiKey "$(APPSTORE_API_KEY)" --apiIssuer "$(APPSTORE_API_ISSUER)"
	@echo "Upload complete! Check App Store Connect for processing status."

# All-in-one: build, validate, upload
appstore-all: appstore validate upload

# ============================================================================
# Marketing Assets (Screenshots & Preview Video)
# ============================================================================
# Prerequisites:
#   1. ImageMagick (full): brew install imagemagick-full (required for font rendering)
#   2. ffmpeg: brew install ffmpeg
#   3. Synthetic data with demo items: make -C distribution synthetic-data
#
# Usage:
#   make -C distribution marketing-screenshots    # Generate App Store screenshots with captions
#   make -C distribution preview-video            # Record App Store preview video
#   make -C distribution marketing                # Generate all marketing assets
# ============================================================================

# Generate synthetic data for UI tests and marketing
# Requires GEMINI_API_KEY environment variable for AI-generated content
# Run distribution/patch-demo-items.sh after to add demo-specific items
synthetic-data:
	@echo "Generating synthetic data..."
	@$(NIX_SHELL) "cd distribution/rust-data-gen && cargo run --release -- --db-path ../SyntheticData.sqlite"
	@echo "Synthetic data generated at distribution/SyntheticData.sqlite"
	@echo "Run ./distribution/patch-demo-items.sh to add demo items"

# Open app with synthetic data for manual testing
# Uses non-sandboxed build for simpler file access
run-synthetic:
	@$(MAKE) -C $(PROJECT_ROOT) sign SANDBOX=false
	@echo "Setting up synthetic data..."
	@mkdir -p ~/Library/Application\ Support/ClipKitty
	@rm -f ~/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite*
	@rm -rf ~/Library/Application\ Support/ClipKitty/tantivy_index
	@cp $(DIST_DIR)/SyntheticData.sqlite ~/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite
	@echo "Launching app with synthetic data..."
	@cd $(PROJECT_ROOT) && open ClipKitty.app --args --use-simulated-db

# Print background image path (used by CI/scripts)
print-background-image:
	@echo $(BACKGROUND_IMAGE)

# Capture raw marketing screenshots via UI test (with clean environment, uses sandboxed)
# Requires full Xcode installation
marketing-screenshots-capture:
ifeq ($(HAVE_XCODE),false)
	$(error Xcode is required for marketing screenshots. Install Xcode from the App Store.)
endif
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) sign SANDBOX=true
	@$(MAKE) -C $(PROJECT_ROOT) ClipKitty.xcodeproj
	@echo "Capturing marketing screenshots..."
	@rm -rf $(PROJECT_ROOT)/DerivedData
	@$(DIST_DIR)/prepare-screenshot-environment.sh 'cd $(PROJECT_ROOT) && xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination "platform=macOS" -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots 2>&1 | grep -E "(Test Case|passed|failed)" || true'
	@echo "Raw screenshots saved to /tmp/clipkitty_marketing_*.png"

# Process raw screenshots into marketing-ready images
marketing-screenshots-process:
	@echo "Processing screenshots..."
	@BACKGROUND_IMAGE="$(BACKGROUND_IMAGE)" $(DIST_DIR)/generate-marketing-screenshots.sh

# Full screenshot pipeline: capture + process
marketing-screenshots: marketing-screenshots-capture marketing-screenshots-process
	@echo "Marketing screenshots complete! See marketing/ directory"

# Record App Store preview video (uses sandboxed)
# Requires full Xcode installation
preview-video:
ifeq ($(HAVE_XCODE),false)
	$(error Xcode is required for preview video. Install Xcode from the App Store.)
endif
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) sign SANDBOX=true
	@$(MAKE) -C $(PROJECT_ROOT) ClipKitty.xcodeproj
	@echo "Recording preview video..."
	@$(DIST_DIR)/record-preview-video.sh

# Generate all marketing assets
marketing: marketing-screenshots preview-video
	@echo ""
	@echo "=== All Marketing Assets Generated ==="
	@echo "Screenshots: marketing/screenshot_*.png"
	@echo "Video: marketing/app_preview.mov"
	@ls -lh $(PROJECT_ROOT)/marketing/ 2>/dev/null || true
