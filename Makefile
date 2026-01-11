SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP_NAME := ClipKitty
BUNDLE_ID := com.clipkitty.app
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ICON_SOURCE := $(SCRIPT_DIR)/AppIcon.icon

.PHONY: all build bundle icon plist clean

all: build bundle icon plist

build:
	@echo "Building release..."
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release

bundle:
	@echo "Creating app bundle..."
	@rm -rf "$(APP_NAME).app"
	@mkdir -p "$(APP_NAME).app/Contents/MacOS"
	@mkdir -p "$(APP_NAME).app/Contents/Resources"
	@cp ".build/release/$(APP_NAME)" "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"
	@if [ -d ".build/release/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R ".build/release/$(APP_NAME)_$(APP_NAME).bundle/Contents/Resources/"* "$(APP_NAME).app/Contents/Resources/" 2>/dev/null || true; \
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
		rm -f "$(APP_NAME).app/Contents/Resources/AppIcon.icns"; \
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

clean:
	@rm -rf "$(APP_NAME).app"
