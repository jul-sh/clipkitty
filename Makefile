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

# The core app bundle components
APP_BUNDLE := $(APP_NAME).app
APP_BUNDLE_SANDBOXED := $(APP_NAME)-Sandboxed.app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_PLIST := $(APP_BUNDLE)/Contents/Info.plist
APP_ICONS := $(APP_BUNDLE)/Contents/Resources/Assets.car

.PHONY: all clean sign sign-sandboxed screenshot perf build-binary build-binary-sandboxed dmg dmg-sandboxed all-variants appstore validate upload

# App Store signing identity (find yours with: security find-identity -v -p codesigning)
# Set via environment or override: make appstore SIGNING_IDENTITY="Developer ID Application: ..."
SIGNING_IDENTITY ?= 3rd Party Mac Developer Application
INSTALLER_IDENTITY ?= 3rd Party Mac Developer Installer

all: $(APP_BUNDLE) $(APP_ICONS)

all-variants: all build-sandboxed sign-sandboxed

rust:
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd rust-core && cargo run --release --bin generate-bindings"

# Build just the binary using SwiftPM
build-binary: rust
	@echo "Building binary..."
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release $(SWIFT_ARCH_FLAGS)

build-binary-sandboxed: rust
	@echo "Building sandboxed binary..."
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release $(SWIFT_ARCH_FLAGS) -Xswiftc -DSANDBOXED

# Create the bundle structure and copy the binary
$(APP_BINARY): build-binary
	@echo "Creating app bundle structure..."
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	if [ -f "$$BIN_PATH/$(APP_NAME)" ]; then \
		cp "$$BIN_PATH/$(APP_NAME)" "$(APP_BINARY)"; \
	else \
		echo "Error: built binary not found at $$BIN_PATH/$(APP_NAME)" >&2; \
		exit 1; \
	fi
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	if [ -d "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@cp "Sources/App/PrivacyInfo.xcprivacy" "$(APP_BUNDLE)/Contents/Resources/"

build-sandboxed: build-binary-sandboxed $(APP_PLIST) $(ICON_SOURCE)
	@echo "Creating sandboxed app bundle structure..."
	@mkdir -p "$(APP_BUNDLE_SANDBOXED)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE_SANDBOXED)/Contents/Resources"
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	cp "$$BIN_PATH/$(APP_NAME)" "$(APP_BUNDLE_SANDBOXED)/Contents/MacOS/$(APP_NAME)"
	@if [ -d "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" "$(APP_BUNDLE_SANDBOXED)/Contents/Resources/"; \
	fi
	@cp "$(APP_PLIST)" "$(APP_BUNDLE_SANDBOXED)/Contents/Info.plist"
	@cp "Sources/App/PrivacyInfo.xcprivacy" "$(APP_BUNDLE_SANDBOXED)/Contents/Resources/"
	@# Compile icons for sandboxed version
	@xcrun actool "$(ICON_SOURCE)" \
		--compile "$(APP_BUNDLE_SANDBOXED)/Contents/Resources" \
		--platform macosx \
		--target-device mac \
		--minimum-deployment-target 15.0 \
		--app-icon "AppIcon" \
		--include-all-app-icons \
		--output-partial-info-plist /dev/null
	@$(MAKE) sign-sandboxed

# Generate Info.plist
$(APP_PLIST):
	@echo "Generating Info.plist..."
	@mkdir -p "$(APP_BUNDLE)/Contents"
	@swift Scripts/GenInfoPlist.swift "$(APP_PLIST)"
	@touch "$(APP_BUNDLE)"

# Compile icons - depends on APP_BUNDLE to ensure Resources dir exists
$(APP_ICONS): $(ICON_SOURCE) $(APP_BUNDLE)
	@echo "Compiling icons..."
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@if [ -d "$(ICON_SOURCE)" ]; then \
		xcrun actool "$(ICON_SOURCE)" \
			--compile "$(APP_BUNDLE)/Contents/Resources" \
			--platform macosx \
			--target-device mac \
			--minimum-deployment-target 15.0 \
			--app-icon "AppIcon" \
			--include-all-app-icons \
			--output-partial-info-plist /dev/null; \
	else \
		echo "Warning: .icon source not found at $(ICON_SOURCE)"; \
	fi

# Minimal app bundle for tests
$(APP_BUNDLE): $(APP_BINARY) $(APP_PLIST)

# Xcode project generation
ClipKitty.xcodeproj: Scripts/GenXcodeproj.swift $(wildcard Tests/UITests/*.swift)
	@echo "Generating Xcode project..."
	@swift Scripts/GenXcodeproj.swift

clean:
	@git stash push --quiet
	@git clean -fdx
	@git stash pop --quiet || true

sign: $(APP_BUNDLE)
	@echo "Signing with standard entitlements..."
	@codesign --force --deep --sign - --entitlements Sources/App/ClipKitty.entitlements "$(APP_BUNDLE)"

sign-sandboxed: $(APP_BUNDLE_SANDBOXED)
	@echo "Signing with sandbox entitlements..."
	@codesign --force --deep --sign - --entitlements Sources/App/ClipKitty-Sandboxed.entitlements "$(APP_BUNDLE_SANDBOXED)"

# Perf runs without icons and only runs perf tests
perf: sign ClipKitty.xcodeproj
	@echo "Running UI Performance Tests..."
	@rm -rf DerivedData
	@xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyPerformanceTests | tee xcodebuild.log
	@swift Scripts/PrintPerfResults.swift

# Build DMG installer
dmg: all sign
	@echo "Building DMG installer..."
	@./Scripts/build-dmg.sh "$(APP_BUNDLE)" "$(APP_NAME).dmg"

dmg-sandboxed: build-sandboxed
	@echo "Building Sandboxed DMG installer..."
	@./Scripts/build-dmg.sh "$(APP_BUNDLE_SANDBOXED)" "$(APP_NAME)-Sandboxed.dmg"

# Screenshot runs everything
screenshot: sign ClipKitty.xcodeproj
	@echo "Running UI Tests..."
	@rm -rf DerivedData
	@xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination 'platform=macOS' -derivedDataPath DerivedData | tee xcodebuild.log
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
# Compiles the .icon format to .icns, then extracts 1024x1024 PNG
icon-png:
	@echo "Compiling icon..."
	@rm -rf .icon-build && mkdir -p .icon-build
	@xcrun actool "$(ICON_SOURCE)" \
		--compile .icon-build \
		--platform macosx \
		--target-device mac \
		--minimum-deployment-target 15.0 \
		--app-icon "AppIcon" \
		--include-all-app-icons \
		--output-partial-info-plist /dev/null
	@echo "Extracting PNG from compiled icon..."
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

# Build and sign for App Store
appstore: build-sandboxed
	@echo "Signing for App Store distribution..."
	@rm -rf "$(APP_BUNDLE_SANDBOXED)"
	@$(MAKE) build-binary-sandboxed
	@mkdir -p "$(APP_BUNDLE_SANDBOXED)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE_SANDBOXED)/Contents/Resources"
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	cp "$$BIN_PATH/$(APP_NAME)" "$(APP_BUNDLE_SANDBOXED)/Contents/MacOS/$(APP_NAME)"
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	if [ -d "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" "$(APP_BUNDLE_SANDBOXED)/Contents/Resources/"; \
	fi
	@cp "$(APP_PLIST)" "$(APP_BUNDLE_SANDBOXED)/Contents/Info.plist"
	@cp "Sources/App/PrivacyInfo.xcprivacy" "$(APP_BUNDLE_SANDBOXED)/Contents/Resources/"
	@xcrun actool "$(ICON_SOURCE)" \
		--compile "$(APP_BUNDLE_SANDBOXED)/Contents/Resources" \
		--platform macosx \
		--target-device mac \
		--minimum-deployment-target 15.0 \
		--app-icon "AppIcon" \
		--include-all-app-icons \
		--output-partial-info-plist /dev/null
	@# Sign with App Store distribution certificate
	@codesign --force --deep --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		--entitlements Sources/App/ClipKitty-Sandboxed.entitlements \
		"$(APP_BUNDLE_SANDBOXED)"
	@echo "Creating installer package..."
	@rm -f "$(APP_NAME).pkg"
	@productbuild --component "$(APP_BUNDLE_SANDBOXED)" /Applications \
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
