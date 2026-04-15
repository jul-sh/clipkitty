{ pkgs, lib }:

# Shared Nix helpers for the ClipKitty flake.
#
# Responsibilities:
#
#   * Define `appSource` — the source tree consumed by Apple/Tuist builds,
#     with all derived-state directories stripped out so a clean checkout and
#     a dirty one hash the same way.
#   * Define `rustSource` — the narrower source tree consumed by Rust builds.
#   * Define the canonical Swift package pinset used by Tuist / SwiftPM and
#     expose a `swiftPackagePin identity` lookup for downstream derivations.
#   * Provide the host-Xcode preflight shell snippet that every Apple-facing
#     derivation must run first.
#   * Provide a `stageAppTree` helper that materializes a writable copy of
#     `appSource` together with the Nix-generated Rust overlay.
#
# The public interface is the attribute set returned at the bottom. Any field
# not listed there is considered private to this file.

let
  repoRoot = ../.;

  # Source filter used by both `appSource` and `rustSource`. We strip
  # everything that's either derived state or explicitly out of scope for
  # Nix-driven builds:
  #
  #   * generated Xcode project/workspace state
  #   * Tuist internal build state (`.build/`, `Derived*/`)
  #   * Bazel output symlinks left behind from the old build graph
  #   * Rust `target/` directories (both at the root and per-crate)
  #   * the `result` symlink from previous `nix build` invocations
  #   * editor / macOS metadata files
  #   * generated SwiftPM resolution files (`Package.resolved`) — the
  #     canonical Swift pinset lives below in `swiftPackagePins`
  #   * `distribution/` — explicitly out of scope for this workstream
  #   * everything under `Sources/ClipKittyRust*` that we know is regenerated
  #     by the Rust overlay, so cached outputs never sneak into the sandbox
  filterCommon = { extraExcludeBaseNames ? [ ] }: path: type:
    let
      base = baseNameOf path;
      rel = lib.removePrefix (toString repoRoot + "/") (toString path);
      # `distribution/` was historically carved out of the Nix build, but
      # `distribution/SparkleUpdater` is a local SwiftPM package that the
      # Tuist manifest depends on via `.package(path:)`, so it must be
      # part of the app source tree. The rest of `distribution/` (DMG
      # building, notarisation scripts, marketing automation) is still
      # out of scope but lives here as inert files — the build never
      # touches them.
      isDist = false;
      # Generated Rust overlay artifacts that live under Sources/ClipKittyRust*
      # — we never want to pick up stale copies of these from a dirty checkout.
      isGeneratedRustOverlay =
        rel == "Sources/ClipKittyRust/libpurr.a"
        || rel == "Sources/ClipKittyRust/purrFFI.h"
        || rel == "Sources/ClipKittyRust/module.modulemap"
        || lib.hasPrefix "Sources/ClipKittyRust/ios-device" rel
        || lib.hasPrefix "Sources/ClipKittyRust/ios-simulator" rel
        || rel == "Sources/ClipKittyRustWrapper/purr.swift";
    in
    !(
      base == ".git"
      || base == ".DS_Store"
      || base == "Package.resolved"
      || base == ".swiftpm"
      || base == ".make"
      || base == "DerivedData"
      || base == "Derived"
      || base == "target"
      || base == "nixbuild"
      || base == "Build"
      || base == "result"
      || base == ".direnv"
      || lib.hasPrefix "bazel-" base
      || lib.hasSuffix ".xcresult" base
      || lib.hasSuffix ".xcodeproj" base
      || lib.hasSuffix ".xcworkspace" base
      # Tuist writes its SwiftPM cache here; it's derived state.
      || rel == "Tuist/.build"
      || lib.hasPrefix "Tuist/.build/" rel
      || isDist
      || isGeneratedRustOverlay
      || builtins.elem base extraExcludeBaseNames
    );

  appSource = lib.cleanSourceWith {
    name = "clipkitty-src";
    src = lib.cleanSource repoRoot;
    filter = filterCommon { };
  };

  # Rust-only source slice. Narrower filter = fewer rebuilds when Swift-only
  # files change.
  #
  # The root Cargo.toml is a workspace that transitively references crates
  # under `distribution/demo-data` and `distribution/rust-data-gen`. We
  # need them to satisfy the workspace's manifest validation even though
  # we never build those crates from the main flake — cargo refuses to
  # load the workspace if any member is missing. They stay explicitly
  # listed below so adding a new workspace member always forces a
  # conscious decision about whether it belongs in `rustSource`.
  rustSource = lib.cleanSourceWith {
    name = "clipkitty-rust-src";
    src = lib.cleanSource repoRoot;
    filter = path: type:
      let
        base = baseNameOf path;
        rel = lib.removePrefix (toString repoRoot + "/") (toString path);
        allowRoot =
          rel == ""
          || rel == "Cargo.toml"
          || rel == "Cargo.lock"
          || rel == "rust-toolchain.toml"
          || rel == "deny.toml";
        allowTree =
          lib.hasPrefix "purr" rel
          || lib.hasPrefix "purr-sync" rel
          || lib.hasPrefix "rust-core" rel
          || lib.hasPrefix "distribution/demo-data" rel
          || lib.hasPrefix "distribution/rust-data-gen" rel
          || lib.hasPrefix "tools/xtask" rel
          # Allow the `distribution/` and `tools/` directories themselves so
          # cleanSourceWith can recurse into the workspace members above.
          || rel == "distribution"
          || rel == "tools";
      in
      (allowRoot || allowTree)
      && !(
        base == ".git"
        || base == "Package.resolved"
        || base == "target"
        || base == ".DS_Store"
        || lib.hasPrefix "bazel-" base
      );
  };

  # Nix-owned Swift package pinset. This is the single source of truth for the
  # remote SwiftPM revisions used by Tuist and local Swift packages.
  #
  # `name` is SwiftPM's case-sensitive display name. `subpath` is the checkout
  # directory name under `.build/checkouts/`. `sha256` is the Nix hash of the
  # stripped fetchgit tree for this revision.
  swiftPackagePins = {
    "grdb.swift" = {
      identity = "grdb.swift";
      name = "GRDB.swift";
      subpath = "GRDB.swift";
      url = "https://github.com/groue/GRDB.swift.git";
      rev = "aa0079aeb82a4bf00324561a40bffe68c6fe1c26";
      version = "7.9.0";
      sha256 = "sha256-bqiHRby5+WHyPv45JENaveVzGRycSZiL2BEc6zCaO6g=";
    };
    "sparkle" = {
      identity = "sparkle";
      name = "Sparkle";
      subpath = "Sparkle";
      url = "https://github.com/sparkle-project/Sparkle.git";
      rev = "066e75a8b3e99962685d6a90cdd5293ebffd9261";
      version = "2.9.1";
      sha256 = "sha256-ltZehumY8/Y+HA3Abbuk6pH73OsVEtV9qEgokuiALzw=";
    };
    "sttextkitplus" = {
      identity = "sttextkitplus";
      name = "STTextKitPlus";
      subpath = "STTextKitPlus";
      url = "https://github.com/krzyzanowskim/STTextKitPlus.git";
      rev = "2ee74906f4d753458eeaa9a2f6d4538aacb86a1d";
      version = "0.3.0";
      sha256 = "sha256-I/p9b/NMp87R2el3g2rtJxt4b54Rqx8aKAYLmP5ds7E=";
    };
  };

  swiftPackagePin = identity:
    if builtins.hasAttr identity swiftPackagePins
    then swiftPackagePins.${identity}
    else throw ''
      No Swift package pin for '${identity}'. Known identities:
        ${lib.concatStringsSep ", " (lib.attrNames swiftPackagePins)}
      Add it to `swiftPackagePins` in nix/lib.nix.
    '';

  # Host Xcode preflight. The Apple build is inherently impure on the path
  # to a real Xcode install — Tuist, xcodebuild, and UniFFI's iOS
  # cross-compile all shell out to `xcrun`. Rather than hide that, we check
  # it explicitly and fail early with a useful message instead of letting a
  # downstream command die with a confusing error.
  xcodePreflightScript = ''
    set -eu
    if [ ! -d /Applications/Xcode.app/Contents/Developer ] && \
       [ ! -d /Applications/Xcode-beta.app/Contents/Developer ]; then
      echo "error: ClipKitty's Nix build requires a host Xcode install at" >&2
      echo "  /Applications/Xcode.app or /Applications/Xcode-beta.app." >&2
      echo "  Tuist, xcodebuild, and UniFFI's iOS cross-compile all shell" >&2
      echo "  out to /usr/bin/xcrun and need the real Xcode." >&2
      exit 1
    fi
    if [ ! -x /usr/bin/xcrun ]; then
      echo "error: /usr/bin/xcrun is missing; install Xcode command-line tools." >&2
      exit 1
    fi
    if ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
      echo "error: xcrun cannot resolve the macOS SDK path." >&2
      exit 1
    fi
  '';

  # Resolve a usable DEVELOPER_DIR for invocations that need Xcode's full
  # platform tree (iOS SDK, xcodebuild, tuist's generator). Exported as a
  # shell variable rather than baked into the Nix store path because the
  # real location is host-dependent.
  resolveDeveloperDirScript = ''
    DEVELOPER_DIR=""
    for candidate in \
      /Applications/Xcode.app/Contents/Developer \
      /Applications/Xcode-beta.app/Contents/Developer; do
      if [ -d "$candidate" ]; then
        DEVELOPER_DIR="$candidate"
        break
      fi
    done
    if [ -z "$DEVELOPER_DIR" ]; then
      echo "error: no usable Xcode install found on host" >&2
      exit 1
    fi
    export DEVELOPER_DIR
  '';

  # Stage `appSource` into a writable directory, drop in the Rust Xcode
  # overlay at the exact paths Project.swift expects, and leave the tree
  # ready for Tuist generation. Callers pass the Rust overlay derivation
  # (built by nix/rust.nix) as `rustOverlay`.
  #
  # The staging is rsync-based so we can later add overlays incrementally
  # (e.g. swift package sources, tuist cache) without re-implementing the
  # copy logic in every consumer derivation.
  stageAppTreeScript = { rustOverlay }: ''
    STAGE_DIR="$PWD/clipkitty-stage"
    mkdir -p "$STAGE_DIR"

    # Copy the (source-filtered) app tree into the staging directory. We
    # use `cp -R` rather than a symlink so subsequent writes (Tuist
    # generation output, overlay files) don't leak back into the Nix store.
    cp -R ${appSource}/. "$STAGE_DIR/"
    chmod -R u+w "$STAGE_DIR"

    # Overlay the Rust bridge artifacts into the exact layout Project.swift
    # expects. The overlay derivation already groups files by their final
    # subdirectory, so we can just copy the top level.
    cp -R ${rustOverlay}/. "$STAGE_DIR/"
    chmod -R u+w "$STAGE_DIR/Sources/ClipKittyRust" "$STAGE_DIR/Sources/ClipKittyRustWrapper"
  '';
in
{
  inherit appSource rustSource;
  inherit swiftPackagePins swiftPackagePin;
  inherit xcodePreflightScript resolveDeveloperDirScript;
  inherit stageAppTreeScript;
}
