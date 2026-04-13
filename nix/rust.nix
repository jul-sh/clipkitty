{ pkgs, lib, rustToolchain, clipkittyLib }:

# Build the Rust side of ClipKitty as declared Nix derivations.
#
# Canonical outputs (tool-agnostic):
#
#   purrHost           host-arch dynamic library + uniffi-bindgen binary,
#                      used solely to drive UniFFI Swift binding generation.
#   purrSwiftBinds     generated Swift source (purr.swift), C header
#                      (purrFFI.h) and module map, with the ClipKitty-
#                      specific patches applied as explicit post-processing
#                      steps.
#   purrMacAarch64     per-target static libraries
#   purrMacX86_64
#   purrMacUniversal   universal macOS static library (lipo'd)
#   purrIosDevice
#   purrIosSim
#   purrBridge         single tree containing the canonical outputs for
#                      downstream consumption.
#
# Xcode adapter output:
#
#   purrXcodeOverlay   thin adapter that reshapes the canonical outputs into
#                      the exact file layout Project.swift expects:
#                        Sources/ClipKittyRust/purrFFI.h
#                        Sources/ClipKittyRust/module.modulemap
#                        Sources/ClipKittyRust/libpurr.a               (universal macOS)
#                        Sources/ClipKittyRust/ios-device/libpurr.a
#                        Sources/ClipKittyRust/ios-simulator/libpurr.a
#                        Sources/ClipKittyRustWrapper/purr.swift
#
# Check output:
#
#   rustTests          `cargo test` over the Rust workspace using the
#                      vendored Cargo lockfile.
#
# Design notes:
#
#   * `purr/src/bin/generate_bindings.rs` exists and is the historical
#     source of truth for how the Swift bindings were produced before the
#     Nix flake took over. We deliberately do NOT call it from Nix: its
#     patches are load-bearing (Swift 6 strict concurrency + the ClipKitty
#     FFI module rename) and we want those patches to show up as explicit
#     `sed` calls in the Nix build log rather than hide inside a Rust
#     binary whose behaviour we'd have to infer from its source.
#
#   * iOS cross-compilation uses host Xcode via `/usr/bin/xcrun`. The host
#     Xcode dependency is validated by `clipkittyLib.xcodePreflightScript`
#     before any cross build runs.

let
  inherit (pkgs) stdenv runCommand;
  rustSrc = clipkittyLib.rustSource;

  # Translate a cargo target triple into the underscored form cargo uses
  # in env var names (e.g. CC_aarch64_apple_ios, CARGO_TARGET_AARCH64_APPLE_IOS_LINKER).
  underscored = target: builtins.replaceStrings [ "-" ] [ "_" ] target;

  # Vendored Cargo registry, hashed from Cargo.lock. Lets the Rust builds run
  # fully offline inside the Nix sandbox without hand-maintaining a cargoHash.
  cargoVendorDir = pkgs.rustPlatform.importCargoLock {
    lockFile = ../Cargo.lock;
  };

  # Cargo config pointing at the vendored registry. Written as a Nix-managed
  # text file so we don't have to fight heredoc indentation rules inside
  # multi-line Nix strings.
  cargoConfigToml = pkgs.writeText "cargo-config.toml" ''
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "${cargoVendorDir}"
  '';

  # Shared cargo environment setup — installs the cargo config above and
  # redirects the target dir out of the workspace.
  cargoEnvSetup = ''
    export CARGO_HOME=$TMPDIR/cargo-home
    mkdir -p "$CARGO_HOME"
    cp ${cargoConfigToml} "$CARGO_HOME/config.toml"
    export CARGO_TARGET_DIR=$TMPDIR/cargo-target
    export MACOSX_DEPLOYMENT_TARGET=14.0
  '';

  # Host dylib + uniffi-bindgen binary. UniFFI's `--library` flag needs a real
  # dylib to introspect exported symbols, not a static archive.
  purrHost = stdenv.mkDerivation {
    pname = "purr-host";
    version = "0.1.0";
    src = rustSrc;

    nativeBuildInputs = [ rustToolchain ];

    buildPhase = ''
      runHook preBuild
      ${cargoEnvSetup}
      cd purr
      cargo build --release --offline --locked --lib
      cargo build --release --offline --locked --bin uniffi-bindgen
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/bin
      cp "$CARGO_TARGET_DIR/release/libpurr.dylib" $out/lib/libpurr.dylib
      cp "$CARGO_TARGET_DIR/release/uniffi-bindgen" $out/bin/uniffi-bindgen
      runHook postInstall
    '';

    doCheck = false;
    dontStrip = true;
  };

  # UniFFI-generated Swift source + C header + modulemap.
  #
  # The two sed passes are load-bearing: Swift 6 strict concurrency forbids
  # the default `private var initializationResult`, and we expose the C
  # module under the name `ClipKittyRustFFI` rather than `purrFFI` so the
  # wrapper module and Tuist target names line up. Keeping these as explicit
  # `sed` steps here (instead of hiding inside generate_bindings.rs) means
  # every transform is visible in the build log and auditable in isolation.
  purrSwiftBinds = runCommand "purr-swift-bindings"
    {
      nativeBuildInputs = [ purrHost rustToolchain ];
    } ''
    # `uniffi-bindgen --library` still consults `cargo metadata` to resolve
    # workspace layout, so we run from inside a writable copy of the Rust
    # source. CARGO_HOME is pointed at the vendored registry to keep it
    # fully offline.
    cp -R ${rustSrc}/. "$TMPDIR/rust-src"
    chmod -R u+w "$TMPDIR/rust-src"
    cd "$TMPDIR/rust-src/purr"

    ${cargoEnvSetup}

    mkdir -p "$out"
    uniffi-bindgen generate \
      --library ${purrHost}/lib/libpurr.dylib \
      --language swift \
      --out-dir "$out"

    sed -i.bak \
      -e 's/private var initializationResult/nonisolated(unsafe) private var initializationResult/' \
      -e 's/#if canImport(purrFFI)/#if canImport(ClipKittyRustFFI)/' \
      -e 's/import purrFFI/import ClipKittyRustFFI/' \
      "$out/purr.swift"
    rm -f "$out/purr.swift.bak"

    printf 'module ClipKittyRustFFI {\n    header "purrFFI.h"\n    export *\n}\n' \
      > "$out/module.modulemap"
  '';

  # Build one Rust target as a static library. For iOS targets we pull SDK /
  # clang / ar paths from host `xcrun`, which is why the derivation is
  # impure in that case — the same deliberate host-Xcode boundary
  # documented in lib.nix.
  buildRustTarget = { target, sdk ? null, deploymentTarget ? null }:
    let targetUnderscored = underscored target;
    in stdenv.mkDerivation ({
      pname = "purr-${target}";
      version = "0.1.0";
      src = rustSrc;

      nativeBuildInputs = [ rustToolchain ];

      buildPhase = ''
        runHook preBuild
        ${cargoEnvSetup}
        cd purr
      '' + lib.optionalString (sdk != null) ''
        ${clipkittyLib.xcodePreflightScript}

        DEV_DIR=""
        for candidate in \
          /Applications/Xcode.app/Contents/Developer \
          /Applications/Xcode-beta.app/Contents/Developer; do
          if [ -d "$candidate/Platforms/iPhoneOS.platform" ]; then
            DEV_DIR="$candidate"
            break
          fi
        done
        if [ -z "$DEV_DIR" ]; then
          echo "error: no Xcode install with iPhoneOS.platform found" >&2
          exit 1
        fi

        # Resolve iOS SDK paths via xcrun using host Xcode, but DO NOT
        # export DEVELOPER_DIR into the cargo environment: Nix's cc-wrapper
        # inspects DEVELOPER_DIR to pick a libSystem for host build scripts,
        # and host Xcode's libSystem is incompatible with Nix stdenv's
        # expected darwin-libSystem path, producing "symbol not found"
        # link failures for proc-macro2, serde_core, etc.
        SDK_PATH=$(DEVELOPER_DIR="$DEV_DIR" /usr/bin/xcrun --sdk ${sdk} --show-sdk-path)
        CC_IOS=$(DEVELOPER_DIR="$DEV_DIR" /usr/bin/xcrun --sdk ${sdk} --find clang)
        AR_IOS=$(DEVELOPER_DIR="$DEV_DIR" /usr/bin/xcrun --sdk ${sdk} --find ar)
        export IPHONEOS_DEPLOYMENT_TARGET=${deploymentTarget}

        CLANG_TARGET=${if sdk == "iphoneos" then "arm64-apple-ios${deploymentTarget}" else "arm64-apple-ios${deploymentTarget}-simulator"}
        CFLAGS_VAL="-isysroot $SDK_PATH -target $CLANG_TARGET -miphoneos-version-min=${deploymentTarget}"

        # Target-specific vars only. Leaving CC/AR/CFLAGS unset means cargo
        # build scripts (which run on the host) use the ambient host
        # toolchain from stdenv rather than the iOS cross-clang.
        export CC_${targetUnderscored}="$CC_IOS"
        export AR_${targetUnderscored}="$AR_IOS"
        export CFLAGS_${targetUnderscored}="$CFLAGS_VAL"
        export CARGO_TARGET_${lib.toUpper targetUnderscored}_LINKER="$CC_IOS"
        # Force rustc's own linker invocation to use the iOS SDK. Without
        # this, the iOS clang picks up Nix's stdenv SDKROOT (which points
        # at MacOSX.sdk) and fails to resolve libiconv / libSystem for iOS.
        export CARGO_TARGET_${lib.toUpper targetUnderscored}_RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SDK_PATH"
        # Stop the cc crate from auto-appending its own xcrun-detected
        # isysroot. We already pass a complete -isysroot via CFLAGS_<target>.
        export CRATE_CC_NO_DEFAULTS=1
      '' + ''

        cargo build --release --offline --locked --target ${target} --lib
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/lib
        cp "$CARGO_TARGET_DIR/${target}/release/libpurr.a" $out/lib/libpurr.a
        runHook postInstall
      '';

      dontStrip = true;
      doCheck = false;
    });

  purrMacAarch64 = buildRustTarget { target = "aarch64-apple-darwin"; };
  purrMacX86_64 = buildRustTarget { target = "x86_64-apple-darwin"; };
  purrIosDevice = buildRustTarget {
    target = "aarch64-apple-ios";
    sdk = "iphoneos";
    deploymentTarget = "26.0";
  };
  purrIosSim = buildRustTarget {
    target = "aarch64-apple-ios-sim";
    sdk = "iphonesimulator";
    deploymentTarget = "26.0";
  };

  # Universal macOS static library. /usr/bin/lipo is a host Apple tool; we
  # use it directly so we don't need to pull in nixpkgs' cctools variant.
  purrMacUniversal = runCommand "purr-macos-universal" { } ''
    mkdir -p $out/lib
    /usr/bin/lipo -create \
      ${purrMacAarch64}/lib/libpurr.a \
      ${purrMacX86_64}/lib/libpurr.a \
      -output $out/lib/libpurr.a
  '';

  # Tool-agnostic canonical bridge tree. One artifact collects every Rust
  # output the Apple build needs, under a stable layout:
  #
  #   $out/
  #     swift/purr.swift
  #     swift/purrFFI.h
  #     swift/module.modulemap
  #     lib/macos/libpurr.a         (universal)
  #     lib/ios-device/libpurr.a
  #     lib/ios-simulator/libpurr.a
  #
  # Consumers that want files in other layouts (e.g. the Xcode overlay)
  # build a thin adapter derivation on top of this one. Keeping the
  # canonical layout stable means the adapters can be reshuffled without
  # rebuilding any Rust.
  purrBridge = runCommand "clipkitty-rust-bridge" { } ''
    mkdir -p $out/swift $out/lib/macos $out/lib/ios-device $out/lib/ios-simulator

    cp ${purrSwiftBinds}/purr.swift       $out/swift/purr.swift
    cp ${purrSwiftBinds}/purrFFI.h        $out/swift/purrFFI.h
    cp ${purrSwiftBinds}/module.modulemap $out/swift/module.modulemap

    cp ${purrMacUniversal}/lib/libpurr.a $out/lib/macos/libpurr.a
    cp ${purrIosDevice}/lib/libpurr.a    $out/lib/ios-device/libpurr.a
    cp ${purrIosSim}/lib/libpurr.a       $out/lib/ios-simulator/libpurr.a
  '';

  # Xcode overlay adapter. Reshapes the canonical bridge tree into the
  # exact file layout Project.swift expects under Sources/ClipKittyRust*.
  #
  # The layout is duplicated by hand here (rather than reading it from the
  # Tuist manifest) because Project.swift already hardcodes these paths as
  # string literals — the Nix overlay is the inverse side of that hardcoded
  # contract.
  purrXcodeOverlay = runCommand "clipkitty-rust-xcode-overlay" { } ''
    mkdir -p \
      $out/Sources/ClipKittyRust \
      $out/Sources/ClipKittyRust/ios-device \
      $out/Sources/ClipKittyRust/ios-simulator \
      $out/Sources/ClipKittyRustWrapper

    # Canonical macOS libpurr.a → repo's flat Sources/ClipKittyRust/libpurr.a.
    cp ${purrBridge}/lib/macos/libpurr.a         $out/Sources/ClipKittyRust/libpurr.a
    cp ${purrBridge}/lib/ios-device/libpurr.a    $out/Sources/ClipKittyRust/ios-device/libpurr.a
    cp ${purrBridge}/lib/ios-simulator/libpurr.a $out/Sources/ClipKittyRust/ios-simulator/libpurr.a

    # The C header and module map sit next to the C shim in
    # Sources/ClipKittyRust/. The Swift wrapper is compiled as part of the
    # ClipKittyRustWrapper target, so purr.swift goes there.
    cp ${purrBridge}/swift/purrFFI.h        $out/Sources/ClipKittyRust/purrFFI.h
    cp ${purrBridge}/swift/module.modulemap $out/Sources/ClipKittyRust/module.modulemap
    cp ${purrBridge}/swift/purr.swift       $out/Sources/ClipKittyRustWrapper/purr.swift
  '';

  # Workspace-level `cargo test`. Kept as a check rather than a package
  # because its value is signal, not an installable artifact.
  rustTests = stdenv.mkDerivation {
    pname = "clipkitty-rust-tests";
    version = "0.1.0";
    src = rustSrc;

    nativeBuildInputs = [ rustToolchain ];

    buildPhase = ''
      runHook preBuild
      ${cargoEnvSetup}
      cargo test --release --offline --locked --workspace
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      touch $out/rust-tests.ok
      runHook postInstall
    '';
  };
in
{
  inherit purrHost purrSwiftBinds;
  inherit purrMacAarch64 purrMacX86_64 purrMacUniversal purrIosDevice purrIosSim;
  inherit purrBridge purrXcodeOverlay;
  inherit rustTests;
}
