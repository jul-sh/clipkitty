{ pkgs, lib, clipkittyLib, rustOutputs }:

# Apple-side Nix derivations for ClipKitty.
#
# Responsibilities:
#
#   * Fetch every Swift package pinned in the committed lockfiles from Nix
#     (no network at build time; each package has an explicit sha256).
#   * Stage a writable source tree that contains:
#       - the source-filtered app checkout (clipkittyLib.appSource),
#       - the Xcode overlay produced by nix/rust.nix,
#       - pre-resolved SwiftPM checkouts and workspace state so Tuist and
#         SwiftPM can run fully offline.
#   * Run `tuist install` + `tuist generate --no-open` inside that staged
#     tree.
#   * Invoke `xcodebuild` against the generated workspace, once per app
#     variant.
#
# Design notes:
#
#   * Tuist/Package.swift is treated as the authoritative SwiftPM manifest.
#     We never rewrite it at build time; instead, we pre-populate
#     `Tuist/.build/checkouts/<identity>` and
#     `Tuist/.build/workspace-state.json` so SwiftPM sees a completed
#     resolution and skips network I/O.
#   * distribution/SparkleUpdater is a local `.package(path:)` dependency
#     of Tuist/Package.swift, which means its own transitive Sparkle pin
#     has to be made available too — we resolve it by materialising the
#     same checkouts layout inside the staged distribution/SparkleUpdater
#     directory.
#   * The app build layer is variant-driven. Every variant reuses the same
#     staged source tree, generator step, and xcodebuild wrapper; only
#     `scheme`, `configuration`, and `destination` change.
#   * Every Apple derivation depends on host Xcode through the preflight
#     script in clipkittyLib. This impurity is deliberate and documented
#     in nix/lib.nix — we don't try to hide it.

let
  inherit (pkgs) runCommand stdenv;

  # --- Swift package fetching -------------------------------------------------
  #
  # Each package we ship transitively through SwiftPM is fetched with
  # `fetchgit` at an explicit sha256. The sha256 is verified by Nix against
  # the (deterministic) clone contents, so a bad lockfile / revision / url
  # drift fails the build loudly instead of silently reshaping the graph.
  #
  # New packages require a one-time hash; use
  #     nix-prefetch-git <url> <revision>
  # to compute it and add the result below.

  # Per-package metadata that can't be inferred purely from Package.resolved.
  # `name` is the SwiftPM display name (case-sensitive, matches the
  # Package.swift `Package(name:)`). `subpath` is the directory name SwiftPM
  # uses under `.build/checkouts/` — it defaults to the repo basename
  # (without `.git`), which we pin explicitly here so a URL reshuffle
  # doesn't silently move files around.
  swiftPackageMeta = {
    "grdb.swift" = {
      name = "GRDB.swift";
      subpath = "GRDB.swift";
      sha256 = "sha256-bqiHRby5+WHyPv45JENaveVzGRycSZiL2BEc6zCaO6g=";
    };
    "sparkle" = {
      name = "Sparkle";
      subpath = "Sparkle";
      sha256 = "sha256-ltZehumY8/Y+HA3Abbuk6pH73OsVEtV9qEgokuiALzw=";
    };
    "sttextkitplus" = {
      name = "STTextKitPlus";
      subpath = "STTextKitPlus";
      sha256 = "sha256-I/p9b/NMp87R2el3g2rtJxt4b54Rqx8aKAYLmP5ds7E=";
    };
  };

  fetchSwiftPackage = identity:
    let
      pin = clipkittyLib.swiftPackagePin identity;
      meta = swiftPackageMeta.${identity} or (throw ''
        No swiftPackageMeta entry for '${identity}'. Compute its sha256 with
          nix-prefetch-git ${pin.url} ${pin.rev}
        and add an entry to swiftPackageMeta in nix/apple.nix.
      '');
    in
    {
      inherit (meta) name subpath;
      inherit (pin) identity url rev version;
      path = pkgs.fetchgit {
        url = pin.url;
        rev = pin.rev;
        sha256 = meta.sha256;
        # SwiftPM checks out repos with their .git directory stripped;
        # match that so the store path stays deterministic.
        fetchSubmodules = false;
        deepClone = false;
        leaveDotGit = false;
      };
    };

  # Identities that Tuist/Package.swift pulls transitively via SwiftPM. The
  # list is maintained by hand because SwiftPM's resolution graph is not
  # something we want to re-derive from Nix — if a new transitive dep shows
  # up in Tuist/Package.resolved, it must be enumerated here too.
  tuistPackageIdentities = [
    "grdb.swift"
    "sttextkitplus"
    "sparkle"
  ];

  sparkleUpdaterPackageIdentities = [
    "sparkle"
  ];


  # --- Workspace-state.json generation ---------------------------------------
  #
  # SwiftPM keeps its resolution state in `.build/workspace-state.json` as
  # well as in `Package.resolved`. Tuist reuses that state as an
  # optimisation: if the state on disk matches the lockfile, it skips
  # re-resolving. We exploit that by writing a state file that tells SwiftPM
  # "these exact revisions are already checked out locally, nothing to
  # fetch."
  #
  # Schema version 7 matches Swift 5.10 / 6.x SwiftPM. Fields (including
  # `basedOn`, `artifacts`, `prebuilts`) must all be present even when
  # empty — SwiftPM fails with `keyNotFound` on missing keys and then
  # falls back to fresh network resolution.
  #
  # We also emit `fileSystem` dependencies for local `.package(path:)`
  # packages (e.g. `distribution/SparkleUpdater`). SwiftPM discovers those
  # via the manifest, so the runtime `location` needs to be patched
  # in-place during staging — we write a placeholder here and a shell
  # step below rewrites it to the real build-time directory.

  remoteDepEntry = pkg: {
    basedOn = null;
    packageRef = {
      identity = pkg.identity;
      kind = "remoteSourceControl";
      location = pkg.url;
      name = pkg.name;
    };
    state = {
      checkoutState = {
        revision = pkg.rev;
      } // (if pkg.version != null then { version = pkg.version; } else { });
      name = "sourceControlCheckout";
    };
    subpath = pkg.subpath;
  };

  # Placeholder location; replaced at staging time with the absolute path
  # of the build dir so SwiftPM can open the local package.
  localDepPlaceholder = "__CLIPKITTY_LOCAL_PACKAGE_ROOT__";

  localDepEntry = { identity, name, subpath, relPath }: {
    basedOn = null;
    packageRef = {
      inherit identity name;
      kind = "fileSystem";
      location = "${localDepPlaceholder}/${relPath}";
    };
    state = {
      name = "fileSystem";
      path = "${localDepPlaceholder}/${relPath}";
    };
    inherit subpath;
  };

  mkWorkspaceState = { remotes, locals }:
    let
      dependencies =
        (map remoteDepEntry remotes)
        ++ (map localDepEntry locals);
    in
    pkgs.writeText "workspace-state.json" (builtins.toJSON {
      object = {
        artifacts = [ ];
        inherit dependencies;
        prebuilts = [ ];
      };
      version = 7;
    });

  tuistFetchedPackages = map fetchSwiftPackage tuistPackageIdentities;
  sparkleFetchedPackages = map fetchSwiftPackage sparkleUpdaterPackageIdentities;

  tuistWorkspaceState = mkWorkspaceState {
    remotes = tuistFetchedPackages;
    locals = [
      {
        identity = "sparkleupdater";
        name = "SparkleUpdater";
        subpath = "sparkleupdater";
        relPath = "distribution/SparkleUpdater";
      }
    ];
  };

  sparkleWorkspaceState = mkWorkspaceState {
    remotes = sparkleFetchedPackages;
    locals = [ ];
  };

  # Shell snippet that materializes a pre-resolved SwiftPM .build tree
  # inside a target directory. The workspace-state.json dropped here
  # still contains the `__CLIPKITTY_LOCAL_PACKAGE_ROOT__` placeholder for
  # local `fileSystem` dependencies — `finalizeWorkspaceStateScript` (run
  # inside `generatedSource.buildPhase`) rewrites it to the current
  # absolute build directory.
  #
  # SwiftPM's checkouts are writable because the toolchain touches marker
  # files inside them during resolution. We use `cp -R` (not symlinks) so
  # the writes don't leak back into the Nix store.
  stageSwiftCheckoutsScript =
    { targetDirVar, packages, workspaceState }:
    let
      copyOne = pkg: ''
        mkdir -p "''$${targetDirVar}/.build/checkouts"
        cp -R ${pkg.path}/. "''$${targetDirVar}/.build/checkouts/${pkg.subpath}"
        chmod -R u+w "''$${targetDirVar}/.build/checkouts/${pkg.subpath}"
      '';
    in
    ''
      mkdir -p "''$${targetDirVar}/.build"
      ${lib.concatStringsSep "\n" (map copyOne packages)}
      cp ${workspaceState} "''$${targetDirVar}/.build/workspace-state.json"
      chmod u+w "''$${targetDirVar}/.build/workspace-state.json"
    '';

  # Rewrite the `__CLIPKITTY_LOCAL_PACKAGE_ROOT__` placeholder in every
  # staged workspace-state.json with the absolute path of the current
  # build directory. Callers pass `packageRootVar` = shell variable
  # holding that absolute path.
  finalizeWorkspaceStateScript = packageRootVar: ''
    for state in \
      "''$${packageRootVar}/Tuist/.build/workspace-state.json" \
      "''$${packageRootVar}/distribution/SparkleUpdater/.build/workspace-state.json"; do
      if [ -f "$state" ]; then
        sed -i.bak \
          -e "s|${localDepPlaceholder}|''$${packageRootVar}|g" \
          "$state"
        rm -f "$state.bak"
      fi
    done
  '';

  # --- Staged source tree ----------------------------------------------------
  #
  # `stagedSource` is the single canonical writable source tree every
  # Apple derivation builds from. It's deliberately a separate derivation
  # so:
  #   * Tuist generation runs exactly once per nix build invocation (via
  #     `generatedSource`, downstream).
  #   * Multiple app-variant builds can share the same generated project
  #     without re-generating it per variant.
  #   * If something goes wrong, you can `nix build .#clipkitty-staged`
  #     and inspect the tree directly.

  stagedSource = runCommand "clipkitty-staged"
    {
      # Staging has no external build tools; it's just `cp`s.
      nativeBuildInputs = [ ];
    } ''
    mkdir -p $out
    cp -R ${clipkittyLib.appSource}/. $out/
    chmod -R u+w $out

    # Overlay the Rust Xcode artifacts into their Project.swift-expected
    # locations. purrXcodeOverlay already lays out the tree under
    # Sources/ClipKittyRust/ and Sources/ClipKittyRustWrapper/; we just
    # merge it into the staged tree.
    cp -R ${rustOutputs.purrXcodeOverlay}/. $out/
    chmod -R u+w $out/Sources/ClipKittyRust $out/Sources/ClipKittyRustWrapper

    # Pre-populate SwiftPM checkouts for the Tuist workspace so the
    # subsequent `tuist install` (and its own SwiftPM run) never hits the
    # network. Workspace-state.json is written with a placeholder for
    # local `fileSystem` package paths; `generatedSource`'s buildPhase
    # rewrites it to the final absolute path at build time.
    TUIST_DIR="$out/Tuist"
    ${stageSwiftCheckoutsScript {
      targetDirVar = "TUIST_DIR";
      packages = tuistFetchedPackages;
      workspaceState = tuistWorkspaceState;
    }}

    # Do the same for distribution/SparkleUpdater — it's a local SwiftPM
    # package that Tuist/Package.swift depends on via `.package(path:)`,
    # and SwiftPM recursively resolves its own .build/ too.
    SPARKLE_DIR="$out/distribution/SparkleUpdater"
    if [ -d "$SPARKLE_DIR" ]; then
      ${stageSwiftCheckoutsScript {
        targetDirVar = "SPARKLE_DIR";
        packages = sparkleFetchedPackages;
        workspaceState = sparkleWorkspaceState;
      }}
    fi
  '';

  # --- Tuist-generated workspace --------------------------------------------
  #
  # `generatedSource` is `stagedSource` plus the result of running
  # `tuist install` followed by `tuist generate --no-open`. After this
  # step the tree has a real `ClipKitty.xcworkspace` and a set of
  # `*.xcodeproj`s under `Tuist/.build/tuist-derived/` ready for
  # `xcodebuild` to consume.
  generatedSource = stdenv.mkDerivation {
    pname = "clipkitty-generated";
    version = "0.0.0";
    src = stagedSource;

    nativeBuildInputs = [ pkgs.tuist pkgs.git ];

    # SwiftPM's manifest compiler invokes `sandbox-exec` internally; that
    # can't nest inside Nix's own Darwin sandbox, so we run this
    # derivation with __noChroot and let it see the host filesystem.
    # This is the same impurity boundary we already cross for host
    # Xcode — see clipkittyLib.xcodePreflightScript.
    __noChroot = true;

    # Tuist shells out to `xcrun` (via the host Xcode), so the preflight
    # runs first. We also need a HOME because Tuist uses
    # `$HOME/.tuist/...` for its local cache.
    buildPhase = ''
      runHook preBuild
      ${clipkittyLib.xcodePreflightScript}
      ${clipkittyLib.resolveDeveloperDirScript}

      # Tuist and SwiftPM both shell out to `xcrun` (to find `swift`,
      # `swiftc`, etc.) and `xcodebuild` indirectly through the host
      # Xcode install. Nix's derivation PATH doesn't include `/usr/bin`
      # by default, so we prepend it — same deliberate host-Xcode
      # boundary enforced by xcodePreflightScript.
      export PATH=/usr/bin:/bin:$PATH

      # Tuist/SwiftPM need a writable HOME for their internal caches,
      # session files, and generated plugins. Point them all inside the
      # build directory so nothing escapes the sandbox.
      export HOME=$TMPDIR/tuist-home
      mkdir -p "$HOME"
      export XDG_STATE_HOME="$HOME/.local/state"
      export XDG_CACHE_HOME="$HOME/.cache"
      mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

      # Tell Project.swift to skip its Rust pre-build action — the Rust
      # overlay is already in place in the staged tree.
      export CLIPKITTY_SKIP_RUST_PREBUILD=1

      # Strip every Nix-stdenv variable that would push a mismatched SDK
      # or cc-wrapper into SwiftPM's manifest compile. SwiftPM must use
      # the host Xcode toolchain — the `clipkittyLib.xcodePreflightScript`
      # already validated that it exists. Leaving any of these set
      # results in 'no such module SwiftShims' / 'SDK is not supported
      # by the compiler' because Nix stdenv's apple-sdk is older than
      # the host Xcode swift compiler.
      unset SDKROOT
      unset MACOSX_DEPLOYMENT_TARGET
      unset NIX_CFLAGS_COMPILE
      unset NIX_CFLAGS_COMPILE_BEFORE
      unset NIX_CFLAGS_LINK
      unset NIX_LDFLAGS
      unset NIX_LDFLAGS_BEFORE
      unset NIX_COREFOUNDATION_RPATH
      unset NIX_DONT_SET_RPATH
      unset NIX_DONT_SET_RPATH_FOR_BUILD
      unset NIX_ENFORCE_NO_NATIVE
      unset NIX_BINTOOLS
      unset NIX_BINTOOLS_WRAPPER_TARGET_BUILD_aarch64_apple_darwin
      unset NIX_BINTOOLS_WRAPPER_TARGET_HOST_aarch64_apple_darwin
      unset NIX_BINTOOLS_WRAPPER_TARGET_BUILD_x86_64_apple_darwin
      unset NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_apple_darwin
      unset NIX_CC
      unset NIX_CC_WRAPPER_TARGET_BUILD_aarch64_apple_darwin
      unset NIX_CC_WRAPPER_TARGET_HOST_aarch64_apple_darwin
      unset NIX_CC_WRAPPER_TARGET_BUILD_x86_64_apple_darwin
      unset NIX_CC_WRAPPER_TARGET_HOST_x86_64_apple_darwin
      unset NIX_HARDENING_ENABLE
      unset NIX_NO_SELF_RPATH
      unset DEVELOPER_DIR_FOR_BUILD

      # Nix stdenv also sets CC/LD/AR/etc to plain names — if those
      # leak into Tuist → xcodebuild, Xcode reuses them as the compiler
      # / linker driver and fails. Unset everything toolchain-ish so
      # host Xcode is the only source of truth.
      unset CC CXX LD AR AS RANLIB STRIP OBJDUMP NM OBJCOPY READELF
      unset CC_FOR_BUILD CXX_FOR_BUILD LD_FOR_BUILD AR_FOR_BUILD

      # After clearing SDKROOT, let xcrun re-resolve it via the host
      # Xcode install. DEVELOPER_DIR was already set by
      # resolveDeveloperDirScript.
      export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)

      # SwiftPM's manifest compiler unconditionally calls
      # `sandbox_apply(3)` to sandbox the compiled Package.swift
      # manifest and any macro-plugin subprocesses. On Darwin inside a
      # Nix build, macOS sandboxes don't nest — sandbox_apply returns
      # EPERM and SwiftPM reports "sandbox-exec: sandbox_apply:
      # Operation not permitted".
      #
      # The `--disable-sandbox` CLI flag only disables SwiftPM's
      # sandbox for *build subprocesses*, not for manifest compilation.
      # The two private IDE* env vars below are the documented fix (same
      # ones Homebrew exports for the identical error); they short-
      # circuit SwiftPM's sandbox_apply call path in both the manifest
      # compiler and macro plugin host.
      export IDEPackageSupportDisableManifestSandbox=1
      export IDEPackageSupportDisablePluginExecutionSandbox=1

      # Rewrite the local-package placeholder in every staged
      # workspace-state.json with the absolute path of the current build
      # directory. Without this, SwiftPM rejects the state file and falls
      # back to a fresh network resolution.
      BUILD_ROOT="$PWD"
      ${finalizeWorkspaceStateScript "BUILD_ROOT"}

      # SwiftPM dependency resolution.
      #
      # We call `swift package resolve` directly rather than
      # `tuist install` for two reasons:
      #
      #   1. `tuist install` wraps `swift package resolve` but does not
      #      forward `--disable-sandbox`. On Swift 5.10+, that flag is
      #      load-bearing inside a Nix build: it propagates
      #      `-disable-sandbox` to the manifest compiler, which
      #      otherwise unconditionally calls `sandbox_apply(3)` and
      #      fails with `Operation not permitted` because macOS
      #      sandboxes don't nest inside `nix-daemon`'s own profile.
      #      See SwiftPM PR #7167 for the history of this flag.
      #
      #   2. Calling `swift package` directly makes the network
      #      boundary obvious. With the pre-staged checkouts and
      #      workspace-state.json this is purely a local graph walk.
      #
      # `tuist generate` still runs the manifest compile itself (for
      # its own Tuist.swift discovery), so we wrap its swift toolchain
      # invocation via SWIFT_EXEC_MANIFEST_FLAGS — Tuist passes
      # whatever's in that env var straight through to swiftc.
      /usr/bin/xcrun swift package \
        --package-path Tuist \
        --disable-sandbox \
        resolve

      if [ -d distribution/SparkleUpdater ]; then
        /usr/bin/xcrun swift package \
          --package-path distribution/SparkleUpdater \
          --disable-sandbox \
          resolve
      fi

      # `tuist generate --no-open` emits the Xcode workspace/projects.
      # Tuist also compiles Tuist/Package.swift through SwiftPM, so we
      # need the same sandbox escape here. TUIST_GENERATE_SPM_DISABLE_SANDBOX
      # is not a thing — so we pre-resolved above and rely on Tuist's
      # up-to-date cache to skip the re-resolve. The manifest compile
      # that Tuist still performs for its own discovery must also
      # bypass the sandbox; we pass the flag via Tuist's generic
      # SPM extra-args env var if the Tuist version supports it, and
      # otherwise fall back to a wrapper script on PATH.
      SPM_SHIM_DIR=$TMPDIR/spm-shim
      mkdir -p "$SPM_SHIM_DIR"
      cat > "$SPM_SHIM_DIR/swift" <<SHIM
      #!/bin/sh
      # Transparent wrapper: forward everything to the real swift, but
      # inject --disable-sandbox into 'swift package ...' invocations
      # so Tuist's internal SPM calls skip sandbox_apply(3) too.
      if [ "\$1" = "package" ]; then
        shift
        exec /usr/bin/xcrun swift package --disable-sandbox "\$@"
      fi
      exec /usr/bin/xcrun swift "\$@"
      SHIM
      chmod +x "$SPM_SHIM_DIR/swift"
      export PATH="$SPM_SHIM_DIR:$PATH"

      tuist generate --no-open --path .
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R . $out/
      runHook postInstall
    '';

    # This derivation is purely deterministic given the staged source and
    # the tuist binary, so no check phase is needed.
    dontStrip = true;
    dontFixup = true;
  };

  # --- xcodebuild wrapper ----------------------------------------------------
  #
  # Every app-variant derivation reuses this wrapper. Given a variant spec
  # it stages `generatedSource` into a writable directory, runs
  # `xcodebuild`, and collects the built `.app` bundle (or equivalent) as
  # the derivation output.
  #
  # Intentional non-features:
  #   * no code signing (`CODE_SIGNING_ALLOWED=NO`),
  #   * no provisioning profile management,
  #   * no DerivedData leak back into the Nix store (we use $TMPDIR).
  #
  # All of that is owned by distribution/ tooling, which is out of scope.

  buildXcodeVariant =
    { pname
    , scheme
    , configuration
    , sdk
    , destination ? null
    , productName
    , productPath ? "${configuration}/${productName}.app"
      # Distribution variants must ship universal (arm64 + x86_64) for
      # macOS intel compatibility; Debug/simulator variants stay
      # host-arch-only for build speed. Pass `universal = true` to
      # force `ONLY_ACTIVE_ARCH=NO` and both slices in ARCHS.
    , universal ? false
    }:
    stdenv.mkDerivation {
      inherit pname;
      version = "0.0.0";
      src = generatedSource;

      nativeBuildInputs = [ pkgs.git ];

      # Same host-Xcode impurity boundary as `generatedSource`.
      # xcodebuild internally shells out to sandbox-exec (for user
      # script phases and macro plugins) and loads frameworks from
      # /Applications/Xcode.app — neither of which is reachable
      # inside Nix's build sandbox.
      __noChroot = true;

      buildPhase = ''
        runHook preBuild
        ${clipkittyLib.xcodePreflightScript}
        ${clipkittyLib.resolveDeveloperDirScript}

        # xcodebuild uses the host Xcode toolchain; same deliberate
        # host-Xcode boundary as generatedSource. Strip every Nix
        # stdenv var that would push a mismatched SDK into swiftc.
        export PATH=/usr/bin:/bin:$PATH
        unset SDKROOT MACOSX_DEPLOYMENT_TARGET
        unset NIX_CFLAGS_COMPILE NIX_CFLAGS_COMPILE_BEFORE NIX_CFLAGS_LINK
        unset NIX_LDFLAGS NIX_LDFLAGS_BEFORE NIX_COREFOUNDATION_RPATH
        unset NIX_DONT_SET_RPATH NIX_DONT_SET_RPATH_FOR_BUILD
        unset NIX_ENFORCE_NO_NATIVE
        unset NIX_BINTOOLS
        unset NIX_BINTOOLS_WRAPPER_TARGET_BUILD_aarch64_apple_darwin
        unset NIX_BINTOOLS_WRAPPER_TARGET_HOST_aarch64_apple_darwin
        unset NIX_BINTOOLS_WRAPPER_TARGET_BUILD_x86_64_apple_darwin
        unset NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_apple_darwin
        unset NIX_CC
        unset NIX_CC_WRAPPER_TARGET_BUILD_aarch64_apple_darwin
        unset NIX_CC_WRAPPER_TARGET_HOST_aarch64_apple_darwin
        unset NIX_CC_WRAPPER_TARGET_BUILD_x86_64_apple_darwin
        unset NIX_CC_WRAPPER_TARGET_HOST_x86_64_apple_darwin
        unset NIX_HARDENING_ENABLE NIX_NO_SELF_RPATH
        unset DEVELOPER_DIR_FOR_BUILD

        # Nix stdenv also sets CC/CXX/LD/AR to plain names like `ld`,
        # which xcodebuild then uses as the linker DRIVER. That breaks
        # because Xcode emits `-Xlinker` flags that only clang-as-driver
        # understands — calling `ld` directly yields `unknown options:
        # -Xlinker`. Unset them so xcodebuild picks the Xcode toolchain
        # binaries directly.
        unset CC CXX LD AR AS RANLIB STRIP OBJDUMP NM OBJCOPY READELF
        unset CC_FOR_BUILD CXX_FOR_BUILD LD_FOR_BUILD AR_FOR_BUILD

        export HOME=$TMPDIR/xcode-home
        mkdir -p "$HOME"

        # CoreSimulator reads `$HOME/Library/Developer/CoreSimulator/Devices`
        # to enumerate installed simulators. If the directory doesn't exist
        # (which is the case for our sandbox HOME), CoreSimulator aborts
        # with "Cannot allocate memory" and xcodebuild reports "Found no
        # destinations for the scheme" even for `-sdk iphonesimulator`
        # builds that don't need a runtime. Seeding an empty directory
        # makes CoreSimulator happy and xcodebuild fall through to SDK-only
        # compilation.
        mkdir -p "$HOME/Library/Developer/CoreSimulator/Devices"

        export CLIPKITTY_SKIP_RUST_PREBUILD=1

        DERIVED=$TMPDIR/derived
        mkdir -p "$DERIVED"

        /usr/bin/xcodebuild \
          -workspace ClipKitty.xcworkspace \
          -scheme ${lib.escapeShellArg scheme} \
          -configuration ${lib.escapeShellArg configuration} \
          -sdk ${lib.escapeShellArg sdk} \
          ${lib.optionalString (destination != null) "-destination ${lib.escapeShellArg destination}"} \
          -derivedDataPath "$DERIVED" \
          CODE_SIGNING_ALLOWED=NO \
          CODE_SIGN_IDENTITY="" \
          CODE_SIGN_ENTITLEMENTS="" \
          DEVELOPMENT_TEAM="" \
          ENABLE_USER_SCRIPT_SANDBOXING=NO \
          SWIFT_DISABLE_SANDBOX=YES \
          OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
          ${lib.optionalString universal "ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64'"} \
          build

        # Collect the built product from DerivedData. Xcode lays it out
        # under `Build/Products/<configuration><-platform>/<product>.app`;
        # the `productPath` argument lets each variant spell out exactly
        # what to collect.
        PRODUCT_DIR="$DERIVED/Build/Products"
        mkdir -p $out
        cp -R "$PRODUCT_DIR/${productPath}" "$out/$(basename "${productPath}")"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # buildPhase already put the product under $out.
        runHook postInstall
      '';

      dontStrip = true;
      dontFixup = true;
    };

  clipkitty = buildXcodeVariant {
    pname = "clipkitty";
    scheme = "ClipKitty";
    configuration = "Release";
    sdk = "macosx";
    destination = "generic/platform=macOS";
    productName = "ClipKitty";
    universal = true;
  };

  # Debug variant used by `nix run .#run` for iterative dev. Matches the
  # old `make run` which forced CONFIGURATION=Debug.
  clipkitty-debug = buildXcodeVariant {
    pname = "clipkitty-debug";
    scheme = "ClipKitty";
    configuration = "Debug";
    sdk = "macosx";
    destination = "generic/platform=macOS";
    productName = "ClipKitty";
    productPath = "Debug/ClipKitty.app";
  };

  clipkitty-hardened = buildXcodeVariant {
    pname = "clipkitty-hardened";
    scheme = "ClipKitty-Hardened";
    configuration = "Hardened";
    sdk = "macosx";
    destination = "generic/platform=macOS";
    productName = "ClipKitty";
    productPath = "Hardened/ClipKitty.app";
    universal = true;
  };

  clipkitty-sparkle = buildXcodeVariant {
    pname = "clipkitty-sparkle";
    scheme = "ClipKittySpark";
    configuration = "SparkleRelease";
    sdk = "macosx";
    destination = "generic/platform=macOS";
    productName = "ClipKitty";
    productPath = "SparkleRelease/ClipKitty.app";
    universal = true;
  };

  # App Store variant. Builds unsigned — the downstream signing step in
  # distribution/ re-signs with the 3rd Party Mac Developer identities
  # against a keychain that only exists in CI or a prepared dev box.
  clipkitty-appstore = buildXcodeVariant {
    pname = "clipkitty-appstore";
    scheme = "ClipKitty";
    configuration = "AppStore";
    sdk = "macosx";
    destination = "generic/platform=macOS";
    productName = "ClipKitty";
    productPath = "AppStore/ClipKitty.app";
    universal = true;
  };

  clipkitty-ios-sim = buildXcodeVariant {
    pname = "clipkitty-ios-sim";
    scheme = "ClipKittyiOS";
    configuration = "Debug";
    sdk = "iphonesimulator";
    destination = "generic/platform=iOS Simulator";
    productName = "ClipKittyiOS";
    productPath = "Debug-iphonesimulator/ClipKittyiOS.app";
  };

  clipkittyIosSmokeTest = buildXcodeVariant {
    pname = "clipkitty-ios-smoke-build";
    scheme = "ClipKittyiOSSmokeTest";
    configuration = "Debug";
    sdk = "iphonesimulator";
    destination = "generic/platform=iOS Simulator";
    productName = "ClipKittyiOSSmokeTest";
    productPath = "Debug-iphonesimulator/ClipKittyiOSSmokeTest.app";
  };

  # Convenience aggregate: `nix build .#all` builds every macOS app
  # variant.
  #
  # iOS simulator variants are intentionally NOT in `all` even though
  # they're exposed as individual packages. Building them requires the
  # host Xcode's "iOS 26.x" platform bundle to be downloaded via Xcode
  # > Settings > Components — that's a separate ~10GB asset from the
  # iOS Simulator SDK, and a clean Xcode install doesn't have it by
  # default. We don't want `nix build .#all` to hard-fail on a host
  # gap that the flake can't fix, so iOS targets stay opt-in.
  all = pkgs.symlinkJoin {
    name = "clipkitty-all";
    paths = [
      clipkitty
      clipkitty-hardened
      clipkitty-sparkle
      clipkitty-appstore
    ];
  };
in
{
  inherit stagedSource generatedSource;
  inherit clipkitty clipkitty-debug clipkitty-hardened clipkitty-sparkle clipkitty-appstore clipkitty-ios-sim;
  inherit clipkittyIosSmokeTest;
  inherit all;
}
