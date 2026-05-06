SHELL := /bin/bash
.DEFAULT_GOAL := help

# Auto-enter the pinned Nix dev shell for every target unless we're already
# inside one. Every recipe that touches host tooling routes through $(IN_NIX).
NIX_DEVELOP := nix develop --no-update-lock-file --experimental-features 'nix-command flakes' .\#default --command
ifeq ($(strip $(IN_NIX_SHELL)),)
IN_NIX := $(NIX_DEVELOP)
else
IN_NIX :=
endif

# `clipkitty` owns the orchestration that benefits from a real language:
# repo invariants, workspace materialization, signing/staging, ASC publishing,
# marketing screenshots, perf traces, appcast XML, secret resolution, and the
# pre-commit hook entrypoint. The Makefile keeps the simple wrappers.
XTASK := $(IN_NIX) cargo run --quiet -p xtask --
PERF_FAIL_ON_HANGS ?= 1
PERF_HANG_THRESHOLD ?= 250

# Pre-commit hook payload — sourced by `make install-hooks`. Kept here (not in
# Rust) so the install path is plain shell.
define PRECOMMIT_HOOK
#!/bin/bash
set -euo pipefail
REPO_ROOT="$$(git rev-parse --show-toplevel)"
cd "$$REPO_ROOT"
if [ -n "$${IN_NIX_SHELL:-}" ]; then
    exec cargo run --quiet -p xtask -- __internal pre-commit
fi
exec nix develop --no-update-lock-file --experimental-features 'nix-command flakes' "$$REPO_ROOT#default" --command cargo run --quiet -p xtask -- __internal pre-commit
endef
export PRECOMMIT_HOOK

SPARKLE_VERSION := 2.9.0
SPARKLE_SHA256 := 01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19
SPARKLE_INSTALL_DIR := /tmp/sparkle

ICTOOL := /Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool

.PHONY: help shell check workspace install-hooks install-sparkle-cli \
        app-hardened app-app-store \
        release-dmg release-macos-appstore release-ios-appstore release-version \
        release-appcast-generate release-appcast-update \
        screenshots-macos screenshots-ios screenshots-ipad intro-video perf \
        site-icon site-landing-page secrets-asc-auth

help: ## Show the supported automation entry points.
	@awk 'BEGIN {FS = ":.*## "; printf "\nClipKitty automation entry points\n\n"} /^[a-zA-Z0-9_.-]+:.*## / { printf "  %-26s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

guard-%:
	@if [ -z "$($*)" ]; then echo "Missing required variable: $*"; exit 1; fi

shell: ## Drop into the pinned Nix dev shell.
	@$(NIX_DEVELOP) bash

check: ## Verify repository invariants (pinned lockfiles + pinned GitHub Actions).
	@$(XTASK) check

workspace: ## Materialize the generated Xcode workspace/project.
	@$(XTASK) workspace

install-hooks: ## Install the repo-managed git pre-commit hook.
	@set -euo pipefail; \
	hooks_dir="$$(git rev-parse --git-path hooks)"; \
	mkdir -p "$$hooks_dir"; \
	printf '%s\n' "$$PRECOMMIT_HOOK" > "$$hooks_dir/pre-commit"; \
	chmod +x "$$hooks_dir/pre-commit"; \
	echo "Installed pre-commit hook at $$hooks_dir/pre-commit"

install-sparkle-cli: ## Install Sparkle CLI tools into /tmp/sparkle.
	@set -euo pipefail; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	url="https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz"; \
	curl -sL "$$url" -o "$$tmp/Sparkle.tar.xz"; \
	echo "$(SPARKLE_SHA256)  $$tmp/Sparkle.tar.xz" | shasum -a 256 --check; \
	mkdir -p "$(SPARKLE_INSTALL_DIR)"; \
	tar -xf "$$tmp/Sparkle.tar.xz" -C "$(SPARKLE_INSTALL_DIR)"; \
	if [ -n "$${GITHUB_PATH:-}" ]; then echo "$(SPARKLE_INSTALL_DIR)/bin" >> "$$GITHUB_PATH"; fi; \
	echo "Sparkle CLI $(SPARKLE_VERSION) installed to $(SPARKLE_INSTALL_DIR)"

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
	@set -euo pipefail; \
	base=$$(awk -F'"' '/"MARKETING_VERSION"[[:space:]]*:[[:space:]]*"/ { print $$4; exit }' Project.swift); \
	if [ -z "$$base" ]; then echo "no MARKETING_VERSION entry in Project.swift" >&2; exit 1; fi; \
	major=$${base%%.*}; rest=$${base#*.}; minor=$${rest%%.*}; \
	count=$$(git rev-list --count HEAD); \
	case "$(FIELD)" in \
	    version) echo "$$major.$$minor.$$count" ;; \
	    build-number) echo "$$count" ;; \
	    *) echo "FIELD must be version|build-number, got: $(FIELD)" >&2; exit 1 ;; \
	esac

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

site-icon: ## Render the public icon PNG via Xcode's ictool.
	@set -euo pipefail; \
	[ -f "$(ICTOOL)" ] || { echo "ictool not found at $(ICTOOL); install Xcode with Icon Composer" >&2; exit 1; }; \
	[ -d AppIcon.icon ] || { echo "icon bundle not found: AppIcon.icon" >&2; exit 1; }; \
	"$(ICTOOL)" AppIcon.icon --export-image --output-file icon.png \
	    --platform macOS --rendition Default --width 512 --height 512 --scale 1; \
	echo "Exported icon → icon.png"

site-landing-page: ## Render the landing page HTML to stdout.
	@set -euo pipefail; \
	[ -f README.md ] || { echo "README not found: README.md" >&2; exit 1; }; \
	cat distribution/landing-page.head.html; \
	$(IN_NIX) cmark-gfm --unsafe -e table README.md \
	    | sed 's|https://raw.githubusercontent.com/jul-sh/clipkitty/gh-pages/||g'; \
	cat distribution/landing-page.foot.html

secrets-asc-auth: guard-FIELD ## Resolve one ASC auth field. Use FIELD=key-id|issuer-id|private-key-b64
	@$(XTASK) secrets asc-auth "$(FIELD)"
