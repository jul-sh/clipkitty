SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP_NAME := ClipKitty
BUNDLE_ID := com.clipkitty.app
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ICON_SOURCE := $(SCRIPT_DIR)/AppIcon.icon
ARCHS ?= arm64 x86_64
SWIFT_ARCH_FLAGS := $(foreach arch,$(ARCHS),--arch $(arch))

.PHONY: all build bundle icon plist clean sign screenshot

all: build bundle icon plist

build:
	@echo "Building release..."
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release $(SWIFT_ARCH_FLAGS)

bundle:
	@echo "Creating app bundle..."
	@rm -rf "$(APP_NAME).app"
	@mkdir -p "$(APP_NAME).app/Contents/MacOS"
	@mkdir -p "$(APP_NAME).app/Contents/Resources"
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	if [ -f "$$BIN_PATH/$(APP_NAME)" ]; then \
		cp "$$BIN_PATH/$(APP_NAME)" "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"; \
	else \
		echo "Error: built binary not found at $$BIN_PATH/$(APP_NAME)" >&2; \
		exit 1; \
	fi
	@BIN_PATH="$$(swift build -c release $(SWIFT_ARCH_FLAGS) --show-bin-path)"; \
	if [ -d "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$$BIN_PATH/$(APP_NAME)_$(APP_NAME).bundle" "$(APP_NAME).app/Contents/Resources/"; \
	fi

icon:
	@echo "Compiling Liquid Glass icon..."
	@if [ -d "$(ICON_SOURCE)" ]; then \
		xcrun actool "$(ICON_SOURCE)" \
			--compile "$(APP_NAME).app/Contents/Resources" \
			--platform macosx \
			--target-device mac \
			--minimum-deployment-target 15.0 \
			--app-icon "AppIcon" \
			--include-all-app-icons \
			--output-partial-info-plist /dev/null; \
		echo "Assets.car generated successfully"; \
	else \
		echo "Warning: .icon source not found at $(ICON_SOURCE)"; \
	fi

plist:
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>CFBundleExecutable</key>' \
		'	<string>ClipKitty</string>' \
		'	<key>CFBundleIdentifier</key>' \
		'	<string>com.clipkitty.app</string>' \
		'	<key>CFBundleName</key>' \
		'	<string>ClipKitty</string>' \
		'	<key>CFBundleDisplayName</key>' \
		'	<string>ClipKitty</string>' \
		'	<key>CFBundleIconName</key>' \
		'	<string>AppIcon</string>' \
		'	<key>CFBundlePackageType</key>' \
		'	<string>APPL</string>' \
		'	<key>CFBundleVersion</key>' \
		'	<string>1.0</string>' \
		'	<key>CFBundleShortVersionString</key>' \
		'	<string>1.0</string>' \
		'	<key>LSMinimumSystemVersion</key>' \
		'	<string>15.0</string>' \
		'	<key>LSUIElement</key>' \
		'	<true/>' \
		'</dict>' \
		'</plist>' > "$(APP_NAME).app/Contents/Info.plist"
	@touch "$(APP_NAME).app"
	@echo "Done! Created $(APP_NAME).app"

sign:
	@echo "Signing with entitlements..."
	@codesign --force --options runtime --entitlements Sources/App/ClipKitty.entitlements --sign - "$(APP_NAME).app"

clean:
	@rm -rf "$(APP_NAME).app"

screenshot: all
	@echo "Taking screenshot..."
	@if [ "$$CI" = "true" ]; then \
		defaults write com.apple.screencapture location $(pwd); \
		killall SystemUIServer; \
	fi
	@"$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" --screenshot-mode --show-panel & \
	APP_PID=$$!; \
	sleep 2; \
	screencapture -x screenshot.png; \
	kill $$APP_PID 2>/dev/null || true
	@echo "Screenshot saved to screenshot.png"
