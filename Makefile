#      (\_/)
#      (o.o)
#      / > Bazel for Apple builds, Nix for Rust toolchain commands

APP_NAME := ClipKitty
SCRIPT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_PRODUCTS := $(SCRIPT_DIR)/Build/Products
READ_BUILD_SETTING := $(SCRIPT_DIR)/Scripts/read-build-setting.sh
BAZEL ?= nix shell --no-update-lock-file --inputs-from . nixpkgs#bazelisk -- bazelisk
NIX_SHELL := ./Scripts/run-in-nix.sh -c

CONFIGURATION ?= Release
VERSION ?= $(shell $(READ_BUILD_SETTING) MARKETING_VERSION)
BUILD_NUMBER ?= $(shell $(READ_BUILD_SETTING) CURRENT_PROJECT_VERSION)
EMBED_LABEL := ClipKitty_$(VERSION)_build_$(BUILD_NUMBER)
BAZEL_ARGS ?=
BAZEL_BUILD_FLAGS := --embed_label="$(EMBED_LABEL)" $(BAZEL_ARGS)

# Pass LOCKED=1 in CI to enforce Cargo.lock (adds --locked to cargo commands)
CARGO_LOCKED := $(if $(filter 1,$(LOCKED)),--locked,)
export LOCKED

# Shared Rust target dir — always resolves to main worktree's target/.
CARGO_TARGET_DIR := $(dir $(abspath $(shell git rev-parse --git-common-dir 2>/dev/null)))target
export CARGO_TARGET_DIR

ifeq ($(CONFIGURATION),Debug)
BAZEL_TARGET := //:ClipKitty
BUILD_SUBDIR := Debug
APP_PATH := $(BUILD_PRODUCTS)/Debug/$(APP_NAME).app
else ifeq ($(CONFIGURATION),Release)
BAZEL_TARGET := //:ClipKittyRelease
BUILD_SUBDIR := Release
APP_PATH := $(BUILD_PRODUCTS)/Release/$(APP_NAME).app
else ifeq ($(CONFIGURATION),SparkleRelease)
BAZEL_TARGET := //:ClipKittySpark
BUILD_SUBDIR := SparkleRelease
APP_PATH := $(BUILD_PRODUCTS)/SparkleRelease/$(APP_NAME).app
else ifeq ($(CONFIGURATION),AppStore)
BAZEL_TARGET := //:ClipKittyAppStore
BUILD_SUBDIR := AppStore
APP_PATH := $(BUILD_PRODUCTS)/AppStore/$(APP_NAME).app
else ifeq ($(CONFIGURATION),Hardened)
BAZEL_TARGET := //:ClipKittyHardened
BUILD_SUBDIR := Hardened
APP_PATH := $(BUILD_PRODUCTS)/Hardened/$(APP_NAME).app
else
$(error Unsupported CONFIGURATION '$(CONFIGURATION)')
endif

# Rust build marker and outputs
ifeq ($(UNIVERSAL),1)
RUST_MARKER := .make/rust-universal.marker
RUST_STALE_MARKER := .make/rust.marker
else
RUST_MARKER := .make/rust.marker
RUST_STALE_MARKER := .make/rust-universal.marker
endif
RUST_LIB := Sources/ClipKittyRust/libpurr.a

BUNDLE_ID := com.eviljuliette.clipkitty
APP_SUPPORT := $(HOME)/Library/Containers/$(BUNDLE_ID)/Data/Library/Application Support/ClipKitty
PERF_FIXTURE_DIR := purr/generated/benchmarks
PERF_DB := $(PERF_FIXTURE_DIR)/synthetic_clipboard.sqlite

SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && echo "Developer ID Application" || echo "-")

.PHONY: all clean rust rust-force rust-cache-clean rust-cache-maybe-clean generate build build-output build-target show-build-settings sign signing api-key provisioning provisioning-secrets run run-perf test unittest uitest mac-appstore-uitest ios-unittest ios-uitest ios-appstore-uitest ios-smoke-build rust-test perf-db perf-bench list-identities

all: rust build

show-build-settings:
	@echo "CONFIGURATION=$(CONFIGURATION)"
	@echo "BAZEL_TARGET=$(BAZEL_TARGET)"
	@echo "APP_PATH=$(APP_PATH)"
	@echo "VERSION=$(VERSION)"
	@echo "BUILD_NUMBER=$(BUILD_NUMBER)"
	@echo "EMBED_LABEL=$(EMBED_LABEL)"

# Marker-based Rust build - shared with Bazel as prebuilt inputs.
$(RUST_MARKER): $(shell git ls-files purr 2>/dev/null)
	@echo "Building Rust core..."
	@$(NIX_SHELL) "cd purr && MACOSX_DEPLOYMENT_TARGET=14.0 UNIVERSAL=$(UNIVERSAL) cargo run $(CARGO_LOCKED) --release --bin generate-bindings"
	@mkdir -p .make
	@rm -f $(RUST_STALE_MARKER)
	@touch $(RUST_MARKER)
	@git rev-parse HEAD:purr > .make/rust-tree-hash 2>/dev/null || true

rust: $(RUST_MARKER) rust-cache-maybe-clean
	@test -f $(RUST_LIB) || (rm -f $(RUST_MARKER) && $(MAKE) $(RUST_MARKER))

rust-force:
	@rm -f $(RUST_MARKER)
	@$(MAKE) rust

generate:
	@echo "Bazel is the authoritative Apple build graph; no project generation step is required."

build:
	@$(MAKE) rust
	@echo "Building $(APP_NAME) ($(CONFIGURATION)) with Bazel..."
	@$(BAZEL) build $(BAZEL_BUILD_FLAGS) $(BAZEL_TARGET)
	@ARTIFACT="$$( $(BAZEL) cquery $(BAZEL_BUILD_FLAGS) --output=files $(BAZEL_TARGET) | tail -n 1 )"; \
	DEST_DIR="$(BUILD_PRODUCTS)/$(BUILD_SUBDIR)"; \
	rm -rf "$$DEST_DIR"; \
	mkdir -p "$$DEST_DIR"; \
	case "$$ARTIFACT" in \
		*.zip) ditto -x -k "$$ARTIFACT" "$$DEST_DIR" ;; \
		*.ipa) cp "$$ARTIFACT" "$$DEST_DIR/$(APP_NAME).ipa" ;; \
		*) echo "Unsupported Bazel artifact: $$ARTIFACT"; exit 1 ;; \
	esac
	@echo "Materialized build output at $(APP_PATH)"

build-output:
	@echo "$(APP_PATH)"

build-target:
	@echo "$(BAZEL_TARGET)"

sign:
	@echo "Signing $(APP_NAME) (identity: $(SIGNING_IDENTITY), config: $(CONFIGURATION))..."
	@codesign --force --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		"$(APP_PATH)"

signing:
	@./distribution/setup-dev-signing.sh

api-key:
	@mkdir -p $(SCRIPT_DIR)/.make/keys
	@if [ ! -f "$(SCRIPT_DIR)/.make/keys/AuthKey.p8" ]; then \
		echo "Decrypting API key for provisioning..."; \
		./distribution/asc-auth.sh private-key-b64 | base64 --decode > "$(SCRIPT_DIR)/.make/keys/AuthKey.p8"; \
	fi

provisioning:
	@$(MAKE) api-key
	@./distribution/setup-dev-provisioning.sh

provisioning-secrets:
	@./distribution/regenerate-provisioning-secrets.sh

run: CONFIGURATION := Debug
run: all
	@echo "Closing existing $(APP_NAME)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@echo "Opening $(APP_NAME)..."
	@open "$(APP_PATH)"

run-perf: CONFIGURATION := Release
run-perf: all perf-db
	@echo "Closing existing $(APP_NAME)..."
	@pkill -9 $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@echo "Setting up perf test database and index..."
	@mkdir -p "$(APP_SUPPORT)"
	@rm -f "$(APP_SUPPORT)/clipboard-screenshot.sqlite"*
	@rm -rf "$(APP_SUPPORT)"/tantivy_index_*
	@cp "$(PERF_DB)" "$(APP_SUPPORT)/clipboard-screenshot.sqlite"
	@cp -r $(PERF_FIXTURE_DIR)/tantivy_index_* "$(APP_SUPPORT)/"
	@echo "Opening $(APP_NAME) with perf database..."
	@open "$(APP_PATH)" --args --use-simulated-db

clean:
	@rm -rf .make Build
	@$(BAZEL) clean

# Remove Rust build artifacts not accessed in 30+ days from the shared cache.
RUST_CACHE_SENTINEL := $(CARGO_TARGET_DIR)/.last-cache-clean

rust-cache-clean:
	@for d in purr/target .git/cargo-target; do \
		if [ -d "$$d" ]; then \
			echo "Removing legacy $$d (now using shared $(CARGO_TARGET_DIR))..."; \
			rm -rf "$$d"; \
		fi; \
	done
	@if [ -d "$(CARGO_TARGET_DIR)" ]; then \
		echo "Cleaning Rust cache (files unused for 30+ days)..."; \
		find "$(CARGO_TARGET_DIR)" -type f -atime +30 -not -name .last-cache-clean -delete; \
		find "$(CARGO_TARGET_DIR)" -type d -empty -delete; \
	fi
	@mkdir -p "$(CARGO_TARGET_DIR)"
	@touch "$(RUST_CACHE_SENTINEL)"

rust-cache-maybe-clean:
	@if [ ! -f "$(RUST_CACHE_SENTINEL)" ] || \
	    [ -n "$$(find "$(RUST_CACHE_SENTINEL)" -mtime +7 2>/dev/null)" ]; then \
		$(MAKE) rust-cache-clean; \
	fi

test: rust-test unittest uitest

rust-test:
	@echo "Running Rust tests..."
	@$(NIX_SHELL) "cd purr && cargo test $(CARGO_LOCKED)"

unittest:
	@$(MAKE) rust
	@echo "Running macOS unit tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) //:ClipKittyTests $(if $(TEST),--test_filter=$(TEST),)

uitest:
	@$(MAKE) rust
	@echo "Running macOS UI tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) --spawn_strategy=local --test_timeout=600 --test_env=BUILD_WORKSPACE_DIRECTORY="$(SCRIPT_DIR)" //:ClipKittyUITests $(if $(TEST),--test_filter=$(TEST),)

mac-appstore-uitest:
	@$(MAKE) rust
	@echo "Running App Store macOS UI tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) --spawn_strategy=local --test_timeout=600 --test_env=BUILD_WORKSPACE_DIRECTORY="$(SCRIPT_DIR)" //:ClipKittyAppStoreUITests $(if $(TEST),--test_filter=$(TEST),)

ios-unittest:
	@$(MAKE) rust
	@echo "Running iOS unit tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) --spawn_strategy=local --config=ios_sim //:ClipKittyiOSTests $(if $(TEST),--test_filter=$(TEST),)

ios-uitest:
	@$(MAKE) rust
	@echo "Running iOS UI tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) --spawn_strategy=local --test_timeout=600 --config=ios_sim //:ClipKittyiOSUITests $(if $(TEST),--test_filter=$(TEST),)

ios-appstore-uitest:
	@$(MAKE) rust
	@echo "Running App Store iOS UI tests with Bazel..."
	@$(BAZEL) test $(BAZEL_BUILD_FLAGS) --spawn_strategy=local --test_timeout=600 --config=ios_sim //:ClipKittyiOSAppStoreUITests $(if $(TEST),--test_filter=$(TEST),)

ios-smoke-build:
	@$(MAKE) rust
	@echo "Building iOS smoke test app with Bazel..."
	@$(BAZEL) build $(BAZEL_BUILD_FLAGS) --config=ios_device //:ClipKittyiOSSmokeTest

list-identities:
	@echo "Available signing identities:"
	@security find-identity -v -p codesigning | grep -E "(Developer|3rd Party)"

perf-db:
	@echo "Generating performance test database..."
	@$(NIX_SHELL) "cd purr && cargo run $(CARGO_LOCKED) --release --bin generate-perf-db"

perf-bench:
	@echo "Running maintained Rust benchmark..."
	@$(NIX_SHELL) "cd purr && cargo run $(CARGO_LOCKED) --release --bin bench-search $(BENCH_ARGS)"
