#      (\_/)
#      (o.o)
#      / > Distribution, marketing & release targets

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
DIST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Use Nix wrapper for Rust commands only (Swift needs native Xcode tools)
NIX_SHELL := $(PROJECT_ROOT)/Scripts/run-in-nix.sh -c

# Pass LOCKED=1 in CI to enforce Cargo.lock (adds --locked to cargo commands)
CARGO_LOCKED := $(if $(filter 1,$(LOCKED)),--locked,)
export LOCKED

APP_NAME := ClipKitty
DERIVED_DATA := $(PROJECT_ROOT)/DerivedData

# API key directory for automatic provisioning (shared with root Makefile)
API_KEY_DIR := $(PROJECT_ROOT)/.make/keys

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

.PHONY: dmg appstore appstore-local appstore-publish publish icon-png \
        synthetic-data run-synthetic marketing marketing-screenshots \
        marketing-screenshots-capture marketing-screenshots-localized \
        intro-video intro-video-localized video-data screenshot \
        api-key ios-appstore ios-publish ios-appstore-publish \
        ios-marketing-screenshots-localized

# Build DMG installer
dmg:
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=$(CONFIGURATION)
	@echo "Signing for distribution..."
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/MacApp/ClipKitty.oss.entitlements \
		"$(APP_PATH)"
	@echo "Building DMG installer..."
	@$(DIST_DIR)/build-dmg.sh "$(APP_PATH)" "$(PROJECT_ROOT)/$(APP_NAME).dmg"

# Export app icon as PNG (for README, gh-pages, etc.)
ICTOOL := /Applications/Xcode.app/Contents/Applications/Icon\ Composer.app/Contents/Executables/ictool

icon-png:
	@$(ICTOOL) "$(PROJECT_ROOT)/AppIcon.icon" \
		--export-image \
		--output-file $(PROJECT_ROOT)/icon.png \
		--platform macOS \
		--rendition Default \
		--width 512 \
		--height 512 \
		--scale 1

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
		--entitlements $(PROJECT_ROOT)/Sources/MacApp/ClipKitty.appstore.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@echo "Creating installer package..."
	@rm -f "$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@productbuild --component "$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app" /Applications \
		--sign "$(INSTALLER_IDENTITY)" \
		"$(PROJECT_ROOT)/$(APP_NAME).pkg"
	@echo "Installer package created: $(PROJECT_ROOT)/$(APP_NAME).pkg"

# Build + sign + package for App Store locally (no upload)
# Auto-resolves version from Project.swift + git commit count (same as CI).
# Usage: make -C distribution appstore-local [VERSION=x.y.z]
appstore-local:
	@$(DIST_DIR)/setup-signing.sh; \
	PROV="$(PROVISIONING_PROFILE)"; \
	if [ -z "$$PROV" ]; then \
		echo "Decrypting provisioning profile from secrets..."; \
		"$(DIST_DIR)/read-secret.sh" PROVISION_PROFILE_BASE64 \
			| base64 --decode > "$(PROJECT_ROOT)/ClipKitty.provisionprofile"; \
		PROV="$(PROJECT_ROOT)/ClipKitty.provisionprofile"; \
	fi; \
	if [ -z "$(VERSION)" ]; then \
		BASE=$$(grep 'MARKETING_VERSION' "$(PROJECT_ROOT)/Project.swift" | head -1 | sed 's/.*"\(.*\)".*/\1/'); \
		AUTO_VERSION="$$BASE"; \
		echo "Auto-resolved version: $$AUTO_VERSION"; \
	fi; \
	AUTO_BUILD=$$(git -C "$(PROJECT_ROOT)" rev-list --count HEAD); \
	echo "Build number: $$AUTO_BUILD"; \
	$(MAKE) appstore \
		$${PROV:+PROVISIONING_PROFILE=$$PROV} \
		VERSION=$${AUTO_VERSION:-$(VERSION)} \
		BUILD_NUMBER=$${AUTO_BUILD}; \
	STATUS=$$?; \
	$(DIST_DIR)/setup-signing.sh --cleanup; \
	rm -f "$(PROJECT_ROOT)/ClipKitty.provisionprofile"; \
	exit $$STATUS

# Validate the installer package against App Store Connect requirements
# Must match the provisioning profile, bundle ID, and team info exactly
appstore-validate:
	@xcrun altool --validate-app \
		--file "$(PROJECT_ROOT)/$(APP_NAME).pkg" \
		--type osx \
		--apiKey "$(API_KEY_ID)" \
		--apiIssuer "$(API_ISSUER_ID)" \
		-v

# Publish using custom upload script (handles metadata, screenshots, etc.)
# Usage: make -C distribution publish [VERSION=x.y.z] [PUBLISH_FLAGS=--force]
PUBLISH_FLAGS ?=

publish:
	@$(DIST_DIR)/publish.py $(PUBLISH_FLAGS) $(if $(VERSION),--version $(VERSION),)

# ============================================================================
# Combined: Build + Publish to App Store Connect
# ============================================================================
# Usage (local):
#   make -C distribution appstore-publish VERSION=1.2.3
#
# Usage (with explicit provisioning profile):
#   make -C distribution appstore-publish \
#     PROVISIONING_PROFILE=path/to/profile VERSION=1.2.3
#
# If PROVISIONING_PROFILE is not set, the provisioning profile is
# auto-decrypted from secrets/ using the local age key or CI env.
# ============================================================================

appstore-publish:
	@$(DIST_DIR)/setup-signing.sh; \
	PROV="$(PROVISIONING_PROFILE)"; \
	if [ -z "$$PROV" ]; then \
		echo "Decrypting provisioning profile from secrets..."; \
		"$(DIST_DIR)/read-secret.sh" PROVISION_PROFILE_BASE64 \
			| base64 --decode > "$(PROJECT_ROOT)/ClipKitty.provisionprofile"; \
		PROV="$(PROJECT_ROOT)/ClipKitty.provisionprofile"; \
	fi; \
	$(MAKE) appstore \
		$${PROV:+PROVISIONING_PROFILE=$$PROV} \
		$(if $(VERSION),VERSION=$(VERSION),) \
		$(if $(BUILD_NUMBER),BUILD_NUMBER=$(BUILD_NUMBER),) && \
	$(MAKE) publish $(if $(PUBLISH_FLAGS),PUBLISH_FLAGS=$(PUBLISH_FLAGS),); \
	STATUS=$$?; \
	$(DIST_DIR)/setup-signing.sh --cleanup; \
	exit $$STATUS

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
	@$(NIX_SHELL) "cd $(PROJECT_ROOT) && cargo run $(CARGO_LOCKED) -p rust-data-gen --release -- --db-path $(DIST_DIR)/SyntheticData.sqlite"
	@echo "Synthetic data generated at distribution/SyntheticData.sqlite"
	@echo "Run ./distribution/patch-demo-items.sh to add demo items"

# Sandboxed app container path
CONTAINER_APP_SUPPORT := ~/Library/Containers/com.eviljuliette.clipkitty/Data/Library/Application\ Support/ClipKitty

# Open app with synthetic data for manual testing
run-synthetic:
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=Debug
	@echo "Setting up synthetic data..."
	@mkdir -p $(CONTAINER_APP_SUPPORT)
	@rm -f $(CONTAINER_APP_SUPPORT)/clipboard-screenshot.sqlite*
	@rm -rf $(CONTAINER_APP_SUPPORT)/tantivy_index*
	@cp $(DIST_DIR)/SyntheticData.sqlite $(CONTAINER_APP_SUPPORT)/clipboard-screenshot.sqlite
	@echo "Launching app with synthetic data..."
	@open "$(DERIVED_DATA)/Build/Products/Debug/$(APP_NAME).app" --args --use-simulated-db

# Capture marketing screenshots via UI test (with clean environment, uses AppStore config)
# Screenshots are captured at 16:10 aspect ratio and upscaled to 2880×1800 by the test.
marketing-screenshots-capture:
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/MacApp/ClipKitty.appstore.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@echo "Capturing marketing screenshots..."
	@$(DIST_DIR)/prepare-screenshot-environment.sh 'cd $(PROJECT_ROOT) && xcodebuild test -scheme ClipKittyUITests -configuration AppStore -destination "platform=macOS" -derivedDataPath DerivedData $(if $(SKIP_SIGNING),CODE_SIGNING_ALLOWED=NO,) -only-testing:ClipKittyUITests/ClipKittyUITests/testTakeMarketingScreenshots 2>&1 | grep -E "(Test Case|passed|failed)" || true'
	@mkdir -p $(PROJECT_ROOT)/marketing/en
	@cp /tmp/clipkitty_marketing_1_history.png $(PROJECT_ROOT)/marketing/en/screenshot_1.png
	@cp /tmp/clipkitty_marketing_2_search.png $(PROJECT_ROOT)/marketing/en/screenshot_2.png
	@cp /tmp/clipkitty_marketing_3_filter.png $(PROJECT_ROOT)/marketing/en/screenshot_3.png
	@echo "Screenshots saved to marketing/en/"

# Full screenshot pipeline (English only)
marketing-screenshots: marketing-screenshots-capture
	@echo "Marketing screenshots complete! See marketing/ directory"

# Alias for quick English-only screenshot capture
screenshot: marketing-screenshots-capture

# Capture localized screenshots for all supported locales.
# Each locale's screenshots are saved to marketing/{locale}/screenshot_*.png.
# The app UI is localized via -AppleLanguages and demo content is patched.
# Database selection: uses SyntheticData.sqlite for English, SyntheticData_{locale}.sqlite for others.
# Note: All databases share the same images (with locale column); only text items differ per locale.
marketing-screenshots-localized:
	@$(DIST_DIR)/patch-demo-items.sh
	@$(MAKE) -C $(PROJECT_ROOT) all CONFIGURATION=AppStore
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements $(PROJECT_ROOT)/Sources/MacApp/ClipKitty.appstore.entitlements \
		"$(DERIVED_DATA)/Build/Products/AppStore/$(APP_NAME).app"
	@rm -f /tmp/clipkitty_screenshot_locale.txt
	@rm -f /tmp/clipkitty_screenshot_db.txt
	@for locale in $(SCREENSHOT_LOCALES); do \
		echo "Capturing screenshots for $$locale..."; \
		mkdir -p $(PROJECT_ROOT)/marketing/$$locale; \
		echo "$$locale" > /tmp/clipkitty_screenshot_locale.txt; \
		if [ "$$locale" = "en" ]; then \
			echo "SyntheticData.sqlite" > /tmp/clipkitty_screenshot_db.txt; \
		else \
			echo "SyntheticData_$$locale.sqlite" > /tmp/clipkitty_screenshot_db.txt; \
		fi; \
		$(DIST_DIR)/prepare-screenshot-environment.sh \
			"cd $(PROJECT_ROOT) && xcodebuild test \
				-scheme ClipKittyUITests \
				-configuration AppStore \
				-destination \"platform=macOS\" \
				-derivedDataPath DerivedData \
				$(if $(SKIP_SIGNING),CODE_SIGNING_ALLOWED=NO,) \
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
	@rm -f /tmp/clipkitty_screenshot_locale.txt /tmp/clipkitty_screenshot_db.txt
	@echo "All localized screenshots complete!"

# Generate all marketing assets
marketing: marketing-screenshots-localized
	@echo "All marketing assets generated!"

# Generate video-specific synthetic database (based on normal SyntheticData + video items)
video-data:
	@echo "Generating video database..."
	@cp $(DIST_DIR)/SyntheticData.sqlite $(DIST_DIR)/SyntheticData_video.sqlite
	@$(NIX_SHELL) "cd $(PROJECT_ROOT) && cargo run $(CARGO_LOCKED) -p rust-data-gen --release -- --video-only --db-path $(DIST_DIR)/SyntheticData_video.sqlite"
	@echo "Injecting images into video database..."
	@python3 $(DIST_DIR)/inject-images.py $(DIST_DIR)/SyntheticData_video.sqlite en
	@echo "Video database generated at distribution/SyntheticData_video.sqlite"

# Record intro video using video-specific database
intro-video: video-data
	@echo "Recording intro video..."
	@$(DIST_DIR)/prepare-screenshot-environment.sh \
		"$(DIST_DIR)/record-preview-video.sh \
			--db SyntheticData_video.sqlite \
			--output intro_video.mov \
			--duration 30"
	@echo "Intro video saved!"

# Generate video databases for all locales and record localized intro videos.
# Each locale gets its own video database and output video file.
intro-video-localized:
	@rm -f /tmp/clipkitty_screenshot_locale.txt
	@set -e; for locale in $(SCREENSHOT_LOCALES); do \
		echo "=== Recording intro video for $$locale ==="; \
		echo "$$locale" > /tmp/clipkitty_screenshot_locale.txt; \
		if [ "$$locale" = "en" ]; then \
			cp $(DIST_DIR)/SyntheticData.sqlite $(DIST_DIR)/SyntheticData_video.sqlite; \
		else \
			cp $(DIST_DIR)/SyntheticData_$$locale.sqlite $(DIST_DIR)/SyntheticData_video.sqlite; \
		fi; \
		$(NIX_SHELL) "cd $(PROJECT_ROOT) && cargo run $(CARGO_LOCKED) -p rust-data-gen --release -- --video-only --locale $$locale --db-path $(DIST_DIR)/SyntheticData_video.sqlite"; \
		python3 $(DIST_DIR)/inject-images.py $(DIST_DIR)/SyntheticData_video.sqlite $$locale; \
		mkdir -p $(PROJECT_ROOT)/marketing/$$locale; \
		$(DIST_DIR)/prepare-screenshot-environment.sh \
			"$(DIST_DIR)/record-preview-video.sh \
				--db SyntheticData_video.sqlite \
				--output $$locale/intro_video.mov \
				--duration 30"; \
		echo "  $$locale video saved to marketing/$$locale/intro_video.mov"; \
	done
	@rm -f /tmp/clipkitty_screenshot_locale.txt
	@echo "All localized intro videos complete!"

# ============================================================================
# iOS App Store Submission
# ============================================================================
# Usage:
#   make -C distribution ios-appstore VERSION=1.11.0 BUILD_NUMBER=123
#   make -C distribution ios-appstore-publish VERSION=1.11.0 BUILD_NUMBER=123
#
# The iOS pipeline uses xcodebuild archive + exportArchive to produce an IPA.
# Automatic provisioning via ASC API key handles cert + profile management.
# ============================================================================

# Decrypt App Store Connect API key for automatic provisioning
api-key:
	@mkdir -p $(API_KEY_DIR)
	@if [ ! -f "$(API_KEY_DIR)/AuthKey.p8" ]; then \
		echo "Decrypting API key for provisioning..."; \
		$(DIST_DIR)/asc-auth.sh private-key-b64 | base64 --decode > "$(API_KEY_DIR)/AuthKey.p8"; \
	fi

IOS_BUNDLE_ID := com.eviljuliette.clipkitty
IOS_ARCHIVE_PATH = $(DERIVED_DATA)/ClipKittyiOS.xcarchive
IOS_IPA_PATH = $(PROJECT_ROOT)/ClipKittyiOS.ipa
IOS_SCREENSHOT_LOCALES := $(SCREENSHOT_LOCALES)

# Build iOS archive and export IPA for App Store
ios-appstore:
	@echo "Archiving ClipKittyiOS (AppStore)..."
	@xcodebuild archive \
		-workspace $(PROJECT_ROOT)/$(APP_NAME).xcworkspace \
		-scheme ClipKittyiOS-AppStore \
		-archivePath $(IOS_ARCHIVE_PATH) \
		-destination "generic/platform=iOS" \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
	@echo "Exporting IPA..."
	@xcodebuild -exportArchive \
		-archivePath $(IOS_ARCHIVE_PATH) \
		-exportOptionsPlist $(DIST_DIR)/ExportOptions-iOS.plist \
		-exportPath $(PROJECT_ROOT)
	@echo "IPA exported: $(IOS_IPA_PATH)"

# Publish iOS app to App Store Connect (metadata + binary)
ios-publish:
	@$(DIST_DIR)/publish.py --platform ios $(PUBLISH_FLAGS) $(if $(VERSION),--version $(VERSION),)

# Combined: Build + Publish iOS to App Store Connect
ios-appstore-publish: ios-appstore ios-publish

# ============================================================================
# iOS Marketing Screenshots (Simulator)
# ============================================================================

# Capture localized iOS screenshots for all supported locales.
# Runs XCUITests on iPhone 16 Pro Max simulator.
ios-marketing-screenshots-localized:
	@$(DIST_DIR)/patch-demo-items.sh
	@rm -f /tmp/clipkitty_ios_screenshot_locale.txt /tmp/clipkitty_ios_screenshot_db.txt
	@for locale in $(IOS_SCREENSHOT_LOCALES); do \
		echo "Capturing iOS screenshots for $$locale..."; \
		mkdir -p $(PROJECT_ROOT)/marketing-ios/$$locale; \
		echo "$$locale" > /tmp/clipkitty_ios_screenshot_locale.txt; \
		if [ "$$locale" = "en" ]; then \
			echo "SyntheticData.sqlite" > /tmp/clipkitty_ios_screenshot_db.txt; \
		else \
			if [ -f "$(DIST_DIR)/SyntheticData_$$locale.sqlite" ]; then \
				echo "SyntheticData_$$locale.sqlite" > /tmp/clipkitty_ios_screenshot_db.txt; \
			else \
				echo "SyntheticData.sqlite" > /tmp/clipkitty_ios_screenshot_db.txt; \
			fi; \
		fi; \
		xcodebuild test \
			-workspace $(PROJECT_ROOT)/$(APP_NAME).xcworkspace \
			-scheme ClipKittyiOSUITests \
			-destination "platform=iOS Simulator,name=iPhone 16 Pro Max" \
			-derivedDataPath $(DERIVED_DATA) \
			$(if $(SKIP_SIGNING),CODE_SIGNING_ALLOWED=NO,) \
			-only-testing:ClipKittyiOSUITests/ClipKittyiOSScreenshotTests/testTakeMarketingScreenshots \
			2>&1 | grep -E "(Test Case|passed|failed)" || true; \
		if [ "$$locale" = "en" ]; then \
			cp /tmp/clipkitty_ios_marketing_1_history.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_1.png 2>/dev/null || true; \
			cp /tmp/clipkitty_ios_marketing_2_search.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_2.png 2>/dev/null || true; \
			cp /tmp/clipkitty_ios_marketing_3_filter.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_3.png 2>/dev/null || true; \
		else \
			cp /tmp/clipkitty_ios_$${locale}_marketing_1_history.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_1.png 2>/dev/null || true; \
			cp /tmp/clipkitty_ios_$${locale}_marketing_2_search.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_2.png 2>/dev/null || true; \
			cp /tmp/clipkitty_ios_$${locale}_marketing_3_filter.png $(PROJECT_ROOT)/marketing-ios/$$locale/screenshot_3.png 2>/dev/null || true; \
		fi; \
		echo "  $$locale iOS screenshots saved to marketing-ios/$$locale/"; \
	done
	@rm -f /tmp/clipkitty_ios_screenshot_locale.txt /tmp/clipkitty_ios_screenshot_db.txt
	@echo "All localized iOS screenshots complete!"
