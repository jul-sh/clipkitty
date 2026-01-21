SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP_NAME := ClipKitty
BUNDLE_ID := com.clipkitty.app
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ICON_SOURCE := $(SCRIPT_DIR)/AppIcon.icon
ARCHS ?= arm64 x86_64
SWIFT_ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))

# The core app bundle components
APP_BUNDLE := $(APP_NAME).app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_PLIST := $(APP_BUNDLE)/Contents/Info.plist
APP_ICONS := $(APP_BUNDLE)/Contents/Resources/Assets.car

.PHONY: all clean sign screenshot perf build-binary

all: $(APP_BUNDLE) $(APP_ICONS)

# Build just the binary using SwiftPM
build-binary:
	@echo "Building binary..."
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release $(SWIFT_ARCH_FLAGS)

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

# Generate Info.plist
$(APP_PLIST):
	@echo "Generating Info.plist..."
	@mkdir -p "$(APP_BUNDLE)/Contents"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'\t<key>CFBundleExecutable</key>' \
		'\t<string>$(APP_NAME)</string>' \
		'\t<key>CFBundleIdentifier</key>' \
		'\t<string>$(BUNDLE_ID)</string>' \
		'\t<key>CFBundleName</key>' \
		'\t<string>$(APP_NAME)</string>' \
		'\t<key>CFBundleDisplayName</key>' \
		'\t<string>$(APP_NAME)</string>' \
		'\t<key>CFBundleIconName</key>' \
		'\t<string>AppIcon</string>' \
		'\t<key>CFBundlePackageType</key>' \
		'\t<string>APPL</string>' \
		'\t<key>CFBundleVersion</key>' \
		'\t<string>1.0</string>' \
		'\t<key>CFBundleShortVersionString</key>' \
		'\t<string>1.0</string>' \
		'\t<key>LSMinimumSystemVersion</key>' \
		'\t<string>15.0</string>' \
		'\t<key>LSUIElement</key>' \
		'\t<true/>' \
		'</dict>' \
		'</plist>' > "$(APP_PLIST)"
	@touch "$(APP_BUNDLE)"

# Compile icons (skipped by perf)
$(APP_ICONS): $(ICON_SOURCE)
	@echo "Compiling icons..."
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
	@rm -rf "$(APP_BUNDLE)"
	@rm -rf ClipKitty.xcodeproj
	@rm -rf DerivedData
	@rm -f xcodebuild.log

sign: $(APP_BUNDLE)
	@echo "Signing with entitlements..."
	@codesign --force --options runtime --entitlements Sources/App/ClipKitty.entitlements --sign - "$(APP_BUNDLE)"

# Perf runs without icons and only runs perf tests
perf: $(APP_BUNDLE) ClipKitty.xcodeproj
	@echo "Running UI Performance Tests..."
	@rm -rf DerivedData
	@xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:ClipKittyUITests/ClipKittyPerformanceTests | tee xcodebuild.log
	@swift Scripts/PrintPerfResults.swift

# Screenshot runs everything
screenshot: all ClipKitty.xcodeproj
	@echo "Running UI Tests..."
	@rm -rf DerivedData
	@xcodebuild test -project ClipKitty.xcodeproj -scheme ClipKittyUITests -destination 'platform=macOS' -derivedDataPath DerivedData | tee xcodebuild.log
	@swift Scripts/PrintPerfResults.swift
	@echo "Copying screenshot..."
	@cp /tmp/clipkitty_screenshot.png screenshot.png || true
	@echo "Screenshot saved to screenshot.png"
