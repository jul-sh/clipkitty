#      (\_/)
#      (o.o)
#      / > Distribution, marketing & release targets

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
DIST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := $(PROJECT_ROOT)/Scripts/run-in-nix.sh -c

APP_NAME := ClipKitty
DERIVED_DATA := $(PROJECT_ROOT)/DerivedData

# Build configuration: Release or AppStore (differ only in signing)
CONFIGURATION ?= Release

# Path to the built app bundle (inside DerivedData)
APP_PATH = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

# Signing identities
SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")
APPSTORE_SIGNING_IDENTITY ?= 3rd Party Mac Developer Application
INSTALLER_IDENTITY ?= 3rd Party Mac Developer Installer

# App Store Connect configuration
BUNDLE_ID := com.eviljuliette.clipkitty
PROVISIONING_PROFILE ?=

# All supported screenshot locales (App Store top 10)
SCREENSHOT_LOCALES := en es zh-Hans zh-Hant ja ko fr de pt-BR ru

.PHONY: dmg appstore publish icon-png \
        synthetic-data run-synthetic marketing marketing-screenshots \
        marketing-screenshots-capture marketing-screenshots-localized \
        preview-video

# Build DMG installer
dmg:
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=$(CONFIGURATION)
	@echo "Signing for distribution..."
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty.entitlements \
		"$(APP_PATH)"
	@echo "Building DMG installer..."
	@$(DIST_DIR)/build-dmg.sh "$(APP_PATH)" "$(PROJECT_ROOT)/$(APP_NAME).dmg"

# Export app icon as PNG (for README, gh-pages, etc.)
icon-png:
	@sips -s format png "$(PROJECT_ROOT)/AppIcon.icns" --out $(PROJECT_ROOT)/icon.png

# ============================================================================
# App Store Submission (build only — validate & upload happen in CI)
# ============================================================================
# Usage:
#   make -C distribution appstore                              # Build, sign, package
#   make -C distribution appstore PROVISIONING_PROFILE=path    # With provisioning profile
#
# Certificates required in Keychain:
#   - "3rd Party Mac Developer Application: Your Name (TEAMID)"
#   - "3rd Party Mac Developer Installer: Your Name (TEAMID)"
# ============================================================================

# Build and sign for App Store (always uses AppStore configuration = sandboxed)
appstore:
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore \
		$(if $(VERSION),VERSION=$(VERSION),) \
		$(if $(BUILD_NUMBER),BUILD_NUMBER=$(BUILD_NUMBER),)
	@if [ -n "$(PROVISIONING_PROFILE)" ]; then \
		echo "Embedding provisioning profile..."; \
		cp "$(PROVISIONING_PROFILE)" "$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app/Contents/embedded.provisionprofile"; \
	fi
	@echo "Re-signing for App Store distribution..."
	@codesign --force --options runtime \
		--sign "$(APPSTORE_SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@echo "Creating installer package..."
	@rm -f "$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@productbuild --component "$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app" /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		"$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@echo "App Store package created: $(APP_NAME).pkg"

# ============================================================================
# Publish to App Store Connect (binary + metadata + screenshots)
# ============================================================================
# Usage:
#   make -C distribution publish                    # Upload pkg + metadata + screenshots
#   make -C distribution publish PUBLISH_FLAGS=--dry-run        # Preview without uploading
#   make -C distribution publish PUBLISH_FLAGS=--metadata-only  # Metadata & screenshots only
#
# Requires:
#   - AGE_SECRET_KEY env var (age private key for decrypting secrets/*.age)
#   - ClipKitty.pkg at project root (from `make -C distribution appstore`)
#   - An App Store version in PREPARE_FOR_SUBMISSION state
#   - asc CLI installed (distribution/install-deps.sh)
# ============================================================================

PUBLISH_FLAGS ?=

publish:
	@$(DIST_DIR)/publish.py $(PUBLISH_FLAGS)

# ============================================================================
# Marketing Assets (Screenshots & Preview Video)
# ============================================================================
# Prerequisites:
#   1. ffmpeg: brew install ffmpeg
#   2. Synthetic data with demo items: make -C distribution synthetic-data
#
# Usage:
#   make -C distribution marketing-screenshots    # Generate App Store screenshots
#   make -C distribution preview-video            # Record App Store preview video
#   make -C distribution marketing                # Generate all marketing assets
# ============================================================================

# Generate synthetic data for UI tests and marketing
# Requires GEMINI_API_KEY environment variable for AI-generated content
# Run distribution/patch-demo-items.sh after to add demo-specific items
synthetic-data:
	@echo "Generating synthetic data..."
	@$(NIX_SHELL) "cd $(DIST_DIR)/rust-data-gen && cargo run --release -- --db-path ../SyntheticData.sqlite"
	@echo "Synthetic data generated at distribution/SyntheticData.sqlite"
	@echo "Run ./distribution/patch-demo-items.sh to add demo items"

# Open app with synthetic data for manual testing
run-synthetic:
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=Debug
	@echo "Setting up synthetic data..."
	@mkdir -p ~/Library/Containers/com.eviljuliette.clipkitty/Data/Library/Application\ Support/ClipKitty
	@rm -f ~/Library/Containers/com.eviljuliette.clipkitty/Data/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite*
	@rm -rf ~/Library/Containers/com.eviljuliette.clipkitty/Data/Library/Application\ Support/ClipKitty/tantivy_index*
	@cp $(DIST_DIR)/SyntheticData.sqlite ~/Library/Containers/com.eviljuliette.clipkitty/Data/Library/Application\ Support/ClipKitty/clipboard-screenshot.sqlite
	@echo "Launching app with synthetic data..."
	@open "$(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app" --args --use-simulated-db

# Capture marketing screenshots via UI test (with clean environment, uses AppStore config)
# Screenshots are captured at 16:10 aspect ratio and upscaled to 2880×1800 by the test.
marketing-screenshots-capture:
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@echo "Capturing marketing screenshots..."
	@$(DIST_DIR)/prepare-screenshot-environment.sh 'cd $(PROJECT_ROOT) && xcodebuild test -scheme ClipKittyUITests -destination "platform=macOS" -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots 2>&1 | grep -E "(Test Case|passed|failed)" || true'
	@mkdir -p $(PROJECT_ROOT)/marketing/en
	@cp /tmp/clipkitty_marketing_1_history.png $(PROJECT_ROOT)/marketing/en/screenshot_1.png
	@cp /tmp/clipkitty_marketing_2_search.png $(PROJECT_ROOT)/marketing/en/screenshot_2.png
	@cp /tmp/clipkitty_marketing_3_filter.png $(PROJECT_ROOT)/marketing/en/screenshot_3.png
	@echo "Screenshots saved to marketing/en/"

# Full screenshot pipeline (English only)
marketing-screenshots: marketing-screenshots-capture
	@echo "Marketing screenshots complete! See marketing/ directory"

# Capture localized screenshots for all supported locales.
# Each locale's screenshots are saved to marketing/{locale}/screenshot_*.png.
# The app UI is localized via -AppleLanguages and demo content is patched.
marketing-screenshots-localized:
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@for locale in $(SCREENSHOT_LOCALES); do \
		echo "Capturing screenshots for $$locale..."; \
		mkdir -p $(PROJECT_ROOT)/marketing/$$locale; \
		$(DIST_DIR)/prepare-screenshot-environment.sh \
			"cd $(PROJECT_ROOT) && SCREENSHOT_LOCALE=$$locale xcodebuild test \
				-scheme ClipKittyUITests \
				-destination \"platform=macOS\" \
				-derivedDataPath DerivedData \
				-only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots \
				2>&1 | grep -E '(Test Case|passed|failed)' || true"; \
		if [ "$$locale" = "en" ]; then \
			cp /tmp/clipkitty_marketing_1_history.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_1.png; \
			cp /tmp/clipkitty_marketing_2_search.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_2.png; \
			cp /tmp/clipkitty_marketing_3_filter.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_3.png; \
		else \
			cp /tmp/clipkitty_$${locale}_marketing_1_history.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_1.png; \
			cp /tmp/clipkitty_$${locale}_marketing_2_search.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_2.png; \
			cp /tmp/clipkitty_$${locale}_marketing_3_filter.png $(PROJECT_ROOT)/marketing/$$locale/screenshot_3.png; \
		fi; \
		echo "  $$locale screenshots saved to marketing/$$locale/"; \
	done
	@echo "All localized screenshots complete!"

# Record App Store preview video (uses AppStore config)
preview-video:
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/App/ClipKitty.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@echo "Recording preview video..."
	@$(DIST_DIR)/record-preview-video.sh

# Generate all marketing assets
marketing: marketing-screenshots preview-video
	@echo ""
	@echo "=== All Marketing Assets Generated ==="
	@echo "Screenshots: marketing/*/screenshot_*.png"
	@echo "Video: marketing/app_preview.mov"
	@ls -lh $(PROJECT_ROOT)/marketing/ 2>/dev/null || true
