#      (\_/)
#      (o.o)
#      / > [nix]
#
# Every target is a thin wrapper around `nix build` or `nix run`. The
# real build graph lives in flake.nix + nix/*.nix. CI and dev both go
# through these same wrappers — no direct cargo / tuist / xcodebuild
# calls survive at this layer.
#
# Build variants are published as nix packages and materialised into
# DerivedData/Build/Products/<config>/ClipKitty.app for downstream CI
# steps (codesign, zip, DMG) that already reference that path.

APP_NAME := ClipKitty
DERIVED_DATA := DerivedData
PRODUCTS := $(DERIVED_DATA)/Build/Products

# `make build CONFIGURATION=X` picks the matching nix variant. The
# default maps to `clipkitty` (Release). Anything downstream that shells
# into DerivedData/Build/Products/<config>/ClipKitty.app keeps working
# because this target re-exports the nix result there.
CONFIGURATION ?= Release

VARIANT_Release       := clipkitty
VARIANT_Debug         := clipkitty-debug
VARIANT_Hardened      := clipkitty-hardened
VARIANT_SparkleRelease := clipkitty-sparkle
VARIANT_AppStore      := clipkitty-appstore

NIX_VARIANT := $(VARIANT_$(CONFIGURATION))

# Version override. The nix build always produces whatever Project.swift
# hardcodes (so the store path is deterministic). Release CI wants
# per-commit version/build numbers, so when VERSION / BUILD_NUMBER are
# set we rewrite the Info.plist in the copied-out bundle after nix
# finishes. The signing phase downstream re-signs anyway.
VERSION ?=
BUILD_NUMBER ?=

.PHONY: all rust generate build build-all run test rust-test clean \
        build-release build-debug build-hardened build-sparkle build-appstore

all: build

# `make rust` is retained as a no-op alias: the Rust bridge is already
# part of every `nix build .#clipkitty*` target, so there's no separate
# cargo step to run. We keep the target name because CI workflows and
# wrapper scripts still invoke it.
rust:
	@echo "(make rust) no-op: folded into nix build .#$(NIX_VARIANT)"

# `make generate` materialises the Tuist-generated workspace and
# xcodeproj back into the checkout, so any follow-up step that shells
# directly into xcodebuild (CI's iOS smoke test, screenshot tests, the
# devShell, Xcode.app itself) finds the project files on disk. The
# generated tree comes straight from the `clipkitty-generated` nix
# derivation, so dev and CI run the same Tuist invocation.
generate:
	@echo "Materialising generated Xcode project via nix..."
	@nix build .#clipkitty-generated --out-link result-generated
	@rm -rf $(APP_NAME).xcworkspace $(APP_NAME).xcodeproj Tuist/.build
	@cp -R result-generated/$(APP_NAME).xcworkspace ./
	@cp -R result-generated/$(APP_NAME).xcodeproj ./
	@if [ -d result-generated/Tuist/.build ]; then \
		mkdir -p Tuist; \
		cp -R result-generated/Tuist/.build Tuist/.build; \
	fi
	@chmod -R u+w $(APP_NAME).xcworkspace $(APP_NAME).xcodeproj Tuist/.build 2>/dev/null || true

# Build one variant and materialise it under DerivedData/Build/Products
# so downstream CI steps (codesign, zip, Sparkle, DMG, notarisation)
# find the .app at the exact path they expect.
build:
	@if [ -z "$(NIX_VARIANT)" ]; then \
		echo "error: unknown CONFIGURATION=$(CONFIGURATION)"; \
		echo "known: Release, Debug, Hardened, SparkleRelease, AppStore"; \
		exit 1; \
	fi
	@echo "Building $(APP_NAME) via nix: .#$(NIX_VARIANT) ($(CONFIGURATION))"
	@nix build .#$(NIX_VARIANT) --out-link result-$(CONFIGURATION)
	@mkdir -p "$(PRODUCTS)/$(CONFIGURATION)"
	@rm -rf "$(PRODUCTS)/$(CONFIGURATION)/$(APP_NAME).app"
	@cp -R "result-$(CONFIGURATION)/$(APP_NAME).app" "$(PRODUCTS)/$(CONFIGURATION)/$(APP_NAME).app"
	@chmod -R u+w "$(PRODUCTS)/$(CONFIGURATION)/$(APP_NAME).app"
	@APP_PLIST="$(PRODUCTS)/$(CONFIGURATION)/$(APP_NAME).app/Contents/Info.plist"; \
	if [ -n "$(VERSION)" ]; then \
		echo "Setting CFBundleShortVersionString = $(VERSION)"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$$APP_PLIST"; \
	fi; \
	if [ -n "$(BUILD_NUMBER)" ]; then \
		echo "Setting CFBundleVersion = $(BUILD_NUMBER)"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$$APP_PLIST"; \
	fi
	@echo "Staged at $(PRODUCTS)/$(CONFIGURATION)/$(APP_NAME).app"

build-release: ; @$(MAKE) build CONFIGURATION=Release
build-debug: ; @$(MAKE) build CONFIGURATION=Debug
build-hardened: ; @$(MAKE) build CONFIGURATION=Hardened
build-sparkle: ; @$(MAKE) build CONFIGURATION=SparkleRelease
build-appstore: ; @$(MAKE) build CONFIGURATION=AppStore

build-all:
	@nix build .#all --out-link result-all

run:
	@nix run .#run

test: rust-test

rust-test:
	@nix build .#checks.$$(nix eval --impure --raw --expr 'builtins.currentSystem').rust-tests --no-link

clean:
	@rm -rf result result-* .make DerivedData
