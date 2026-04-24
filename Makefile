SHELL := /bin/bash
.DEFAULT_GOAL := help

# Auto-enter the pinned Nix dev shell for every xtask invocation unless we're
# already inside one. Mirrors the behavior the Makefile on `main` had via
# Scripts/run-in-nix.sh, but without the tracked shell script.
NIX_DEVELOP := nix develop --no-update-lock-file --experimental-features 'nix-command flakes' .\#default --command
ifeq ($(strip $(IN_NIX_SHELL)),)
NIX_RUN := $(NIX_DEVELOP)
else
NIX_RUN :=
endif

XTASK := $(NIX_RUN) cargo run --quiet -p xtask --
PERF_FAIL_ON_HANGS ?= 1
PERF_HANG_THRESHOLD ?= 250

.PHONY: help check workspace install-hooks install-sparkle-cli app-hardened app-app-store release-dmg release-macos-appstore release-ios-appstore release-version release-appcast-generate release-appcast-update screenshots-macos screenshots-ios screenshots-ipad intro-video perf site-icon site-landing-page secrets-asc-auth shell

help: ## Show the supported automation entry points.
	@awk 'BEGIN {FS = ":.*## "; printf "\nClipKitty automation entry points\n\n"} /^[a-zA-Z0-9_.-]+:.*## / { printf "  %-26s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

guard-%:
	@if [ -z "$($*)" ]; then echo "Missing required variable: $*"; exit 1; fi

shell: ## Drop into the pinned Nix dev shell.
	@$(NIX_DEVELOP) bash

check: ## Verify repository invariants (pins + pinned actions).
	@$(XTASK) check

workspace: ## Materialize the generated Xcode workspace/project.
	@$(XTASK) workspace

install-hooks: ## Install the repo-managed git hooks.
	@$(XTASK) env install hooks

install-sparkle-cli: ## Install Sparkle CLI tools into /tmp/sparkle.
	@$(XTASK) env install sparkle-cli

app-hardened: ## Stage the signed hardened macOS app.
	@$(XTASK) app hardened

app-app-store: ## Stage the macOS App Store app bundle.
	@$(XTASK) app app-store

release-dmg: ## Build the signed Sparkle DMG at ClipKitty.dmg.
	@$(XTASK) release dmg

release-macos-appstore: guard-VERSION guard-BUILD_NUMBER ## Publish the macOS App Store build. Use VERSION=... BUILD_NUMBER=...
	@$(XTASK) release macos-appstore "$(VERSION)" "$(BUILD_NUMBER)"

release-ios-appstore: guard-VERSION guard-BUILD_NUMBER ## Publish the iOS App Store build. Use VERSION=... BUILD_NUMBER=...
	@$(XTASK) release ios-appstore "$(VERSION)" "$(BUILD_NUMBER)"

release-version: guard-FIELD ## Resolve release version. Use FIELD=version|build-number
	@$(XTASK) release version "$(FIELD)"

release-appcast-generate: guard-STATE_PATH guard-OUTPUT_PATH ## Render appcast XML. Use STATE_PATH=... OUTPUT_PATH=...
	@$(XTASK) release appcast generate --state-path "$(STATE_PATH)" --output-path "$(OUTPUT_PATH)"

release-appcast-update: guard-STATE_PATH guard-CHANNEL guard-VERSION guard-URL guard-SIGNATURE guard-LENGTH ## Update appcast state. Use STATE_PATH=... CHANNEL=stable|beta VERSION=... URL=... SIGNATURE=... LENGTH=...
	@$(XTASK) release appcast update-state --state-path "$(STATE_PATH)" --channel "$(CHANNEL)" --version "$(VERSION)" --url "$(URL)" --signature "$(SIGNATURE)" --length "$(LENGTH)"

screenshots-macos: ## Capture localized macOS screenshots.
	@$(XTASK) marketing screenshots macos

screenshots-ios: ## Capture localized iOS screenshots.
	@$(XTASK) marketing screenshots ios

screenshots-ipad: ## Capture localized iPad screenshots.
	@$(XTASK) marketing screenshots ipad

intro-video: ## Generate localized intro videos.
	@$(XTASK) marketing intro-video

perf: ## Run the supported performance trace flow. Optional PERF_HANG_THRESHOLD=... PERF_FAIL_ON_HANGS=0|1
	@$(XTASK) perf --hang-threshold "$(PERF_HANG_THRESHOLD)" $(if $(filter 1 true yes,$(PERF_FAIL_ON_HANGS)),--fail-on-hangs,)

site-icon: ## Render the public icon PNG.
	@$(XTASK) site render icon

site-landing-page: ## Render the landing page HTML to stdout.
	@$(XTASK) site render landing-page

secrets-asc-auth: guard-FIELD ## Resolve one ASC auth field. Use FIELD=key-id|issuer-id|private-key-b64
	@$(XTASK) secrets asc-auth "$(FIELD)"
