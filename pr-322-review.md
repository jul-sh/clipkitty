# PR #322 Review: Refactor Apple builds from Tuist to Bazel

**Verdict: Not worth merging as-is.** Merged and reverted within 1 hour (PR #325). No reviews, no comments, no explanation for the revert. CI passed but hid real breakage.

---

## What it does

Replaces Tuist + xcodebuild with Bazel for all Apple builds (macOS + iOS). 69 files changed, +4275/−1607. Deletes the 1001-line `Project.swift` Tuist manifest. Adds `BUILD.bazel`, `MODULE.bazel`, a `bazel/` directory with module variants, plists, and a custom macOS UI test runner. Rewrites CI, Makefile, and distribution scripts. Also bundles unrelated iOS feature work (drag-and-drop export) and a `ClipboardStore` bug fix.

---

## Bugs that will break

### 1. Universal binary support silently dropped

CI passes `UNIVERSAL=1` to every `make build` call, but the new Makefile ignores it entirely for the Bazel build. Only the Rust library (`libpurr.a`) is still built universal. The app binary ships arm64 only. **Intel Mac users get a broken release.** CI passes because runners are arm64.

### 2. iCloud sync crashes debug builds at runtime

The debug entitlements had iCloud container and CloudKit service entitlements removed, but `MACOS_DEBUG_DEFINES` still includes `ENABLE_ICLOUD_SYNC`. The `#if ENABLE_ICLOUD_SYNC` code compiles and executes, but the sandbox entitlements don't grant CloudKit access. Result: runtime crash on sync initialization. CI doesn't catch this because it builds with `SKIP_SIGNING=1` which strips entitlements.

### 3. iOS unit tests missing test host

`ClipKittyiOSTests` doesn't specify a `test_host`, but its library depends on `:ClipKittyiOS_lib` which needs the app's runtime environment (fonts, assets, Rust FFI). A `ClipKittyiOSTestHost` target exists for exactly this purpose but isn't wired up. Tests that access `Bundle.main` resources will crash.

---

## Reward hacks (faking green CI)

### 4. `SKIP_SIGNING=1` is a no-op

The old build used this flag to pass `CODE_SIGNING_ALLOWED=NO` to xcodebuild. The new `build` target doesn't check it at all. It silently does nothing. This "works" only because Bazel produces unsigned bundles by default — the flag is vestigial but gives CI the appearance of controlling signing.

### 5. Test timeout inflated 4x to mask performance regression

```diff
- searchField.waitForExistence(timeout: 15),
+ searchField.waitForExistence(timeout: 60),
```

Bazel's sandbox deletes the Tantivy search index between runs, forcing a full rebuild every time. Rather than solving this (e.g., providing a pre-built index as a test `data` dependency), the timeout is just increased 4x. Tests pass — but they're 4x slower.

### 6. `make generate` exits 0 while doing nothing

```makefile
generate:
    @echo "Bazel is the authoritative Apple build graph; no project generation step is required."
```

Any script or developer habit that runs `make generate && make build` silently succeeds at the now-meaningless step. A hard failure would be safer.

### 7. `LOCKED=1` only locks half the build

CI passes `LOCKED=1` for reproducibility, but it only affects Cargo (`--locked`). The Bazel build has no equivalent enforcement — `MODULE.bazel.lock` is consulted but doesn't fail on drift by default. "Locked build" is only locked for Rust.

---

## Fragile patterns

### 8. `tail -n 1` for artifact discovery

```makefile
ARTIFACT="$$( $(BAZEL) cquery ... --output=files $(BAZEL_TARGET) | tail -n 1 )"
```

If `bazel cquery` outputs multiple files, warnings, or changes its format, this silently picks the wrong file. Used in both the root and distribution Makefiles.

### 9. Hardcoded iOS simulator versions

```python
ios_test_runner(
    name = "ios_unit_runner",
    device_type = "iPhone 17 Pro",
    os_version = "26.4",
)
```

Unlike xcodebuild's auto-selecting `destination "platform=iOS Simulator"`, Bazel requires exact device/OS. Every Xcode point release that changes simulator versions breaks all iOS tests.

### 10. `chmod -R 777` masks permission issues

The test runner uses `chmod -R 777` on extracted bundles three times. Bazel intentionally strips write permissions for hermeticity. Blanket `777` hides any permission-related failures and defeats Bazel's integrity model.

### 11. `--spawn_strategy=local` everywhere defeats sandbox claims

Every test type (macOS UI, iOS unit, iOS UI) uses `--spawn_strategy=local`, which disables Bazel's sandbox. Sandboxed test execution was a theoretical benefit of migrating to Bazel — in practice, none of the tests run sandboxed.

### 12. `codesign --deep` is deprecated

The test runner uses `codesign --force --deep --timestamp=none --sign -` on the test host. Apple deprecated `--deep` because it signs bundles in an undefined order, which can produce invalid signatures for nested frameworks.

### 13. `read-build-setting.sh` silently returns garbage for non-string values

The sed pattern only extracts quoted string values. If called with a list-valued setting (e.g., `MACOS_DEBUG_DEFINES`), grep matches but sed captures nothing — the script prints the raw line without erroring. Only works today because it's only called with two simple string constants.

### 14. VERIFY.md has hardcoded absolute paths

```markdown
pinned by [Package.resolved](/Users/julsh/git/clipkitty/Package.resolved)
```

A security verification document with links to the author's local filesystem. Every other user sees broken links. Undermines the document's purpose.

---

## Other issues

- **Dead file**: `bazel/plists/MacApp-Sparkle.plist` is added but never referenced by any BUILD rule. `ClipKittySpark` uses a genrule-generated plist instead. The static file has duplicated, unparameterized values that can drift.
- **`DEVELOPMENT_TEAM`** declared in `clipkitty_build_settings.bzl` but never used.
- **`MACOS_DEBUG_DEFINES == MACOS_RELEASE_DEFINES`** — identical lists with no comment explaining this is intentional.
- **Bundled unrelated work**: New iOS drag-and-drop export (364 lines of new source + tests), `ClipboardStore` race condition fix, `#if` block re-indentation, and `CLAUDE.MD` deletion. Should be separate PRs.
- **`package(default_visibility = ["//visibility:public"])` on every package** — defeats Bazel's visibility as a module boundary tool.

---

## Security steelman

The migration does have legitimate security benefits:

- **Hardened build auditability**: `bazel/modules/mac_app/hardened/BUILD.bazel` is a 19-line file with an explicit, auditable dependency list. Easier to review than a 1001-line `Project.swift` where any merge could accidentally add a dependency.
- **Codesigning separation**: Signing moves out of the build step into explicit post-build signing, reducing attack surface during compilation.
- **Supply chain pinning**: `MODULE.bazel.lock` pins the entire transitive dependency graph with SHA256 hashes, not just SPM packages.
- **Build reproducibility**: Bazel's deterministic outputs make SLSA attestations more meaningful.

However, these benefits are undermined by the Rust core remaining outside Bazel (the highest-risk component isn't in the hermeticity boundary), `--spawn_strategy=local` disabling sandboxing for all tests, and `chmod 777` overriding Bazel's permission model.

---

## Recommendations if re-attempting

1. **State the motivation** — what specific pain point justifies the migration?
2. **Split the PR** — build migration separate from feature work and bug fixes
3. **Get review** before merging a build system rewrite
4. **Fix universal binary support** — add `--apple_platform_type` / `--ios_multi_cpus` equivalent for macOS fat binaries
5. **Reconcile entitlements with defines** — either remove `ENABLE_ICLOUD_SYNC` from debug defines or restore iCloud entitlements
6. **Wire up `test_host`** on `ClipKittyiOSTests`
7. **Remove dead flags** — don't accept `SKIP_SIGNING` / `UNIVERSAL` without acting on them
8. **Run Bazel alongside Tuist** in CI as a non-blocking check before cutting over
9. **Bring Rust under Bazel** (via `rules_rust`) to close the hermeticity gap
10. **Configure remote caching** — without it, the primary performance benefit of Bazel is absent
