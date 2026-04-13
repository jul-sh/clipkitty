{
  description = "ClipKitty — Nix-owned build of the macOS clipboard manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/832efc09b4caf6b4569fbf9dc01bec3082a00611"; # nixpkgs-unstable
    rust-overlay.url = "github:oxalica/rust-overlay/cc80954a95f6f356c303ed9f08d0b63ca86216ac";
    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";
    keytap.url = "github:jul-sh/keytap/ecbfd924454f3db036aa15f466c84f871f7cb5b8";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, keytap, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        inherit (nixpkgs) lib;
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # ClipKitty's Apple app graph is macOS-only. Everything downstream of
        # flake.nix that touches Xcode, Tuist, or Apple SDKs is gated on
        # Darwin; the flake still exposes Rust-only packages on other systems
        # (for CI runners) and a cross-platform devShell.
        isDarwin = lib.hasSuffix "-darwin" system;

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-std" ];
          targets = [
            "aarch64-apple-darwin"
            "x86_64-apple-darwin"
            "aarch64-apple-ios"
            "aarch64-apple-ios-sim"
          ];
        };

        clipkittyLib = import ./nix/lib.nix { inherit pkgs lib; };

        rustOutputs = import ./nix/rust.nix {
          inherit pkgs lib rustToolchain clipkittyLib;
        };

        applePackages =
          if isDarwin
          then
            import ./nix/apple.nix {
              inherit pkgs lib clipkittyLib rustOutputs;
            }
          else { };

        # App Store Connect CLI — kept alongside the flake because it's
        # historically been a convenience for release tooling, not part of
        # the app graph. Not a package the rest of the flake depends on.
        asc =
          let
            version = "0.43.0";
            src = {
              aarch64-darwin = pkgs.fetchurl {
                url = "https://github.com/rudrankriyam/App-Store-Connect-CLI/releases/download/${version}/asc_${version}_macOS_arm64";
                sha256 = "sha256-5xu0oGdk2WT44G75iSiqIOgWt4enBOHijls1mT5Jo4k=";
              };
              x86_64-darwin = pkgs.fetchurl {
                url = "https://github.com/rudrankriyam/App-Store-Connect-CLI/releases/download/${version}/asc_${version}_macOS_amd64";
                sha256 = "sha256-KBTjyJ51TYsAW/9MtUT33yVxHupKk4g+Mqk3ZlBUchI=";
              };
            }.${system} or null;
          in
          if src == null then null else pkgs.runCommand "asc-${version}" { } ''
            mkdir -p $out/bin
            cp ${src} $out/bin/asc
            chmod +x $out/bin/asc
          '';

        # The Apple package surface is declared in one place so the top-level
        # `packages` attribute and the `packages.all` aggregate stay in sync.
        appleNames = [
          "clipkitty"
          "clipkitty-hardened"
          "clipkitty-sparkle"
          "clipkitty-ios-sim"
        ];

        applePackageSet =
          lib.genAttrs appleNames (name: applePackages.${name});

        # Rust artifacts are exposed individually so they can be built and
        # inspected in isolation without running a full Xcode build. Useful
        # when debugging UniFFI output, iOS cross-compilation, or the lipo
        # step without a full Apple build to observe regressions.
        rustPackageSet = {
          clipkitty-rust-bridge = rustOutputs.purrBridge;
          clipkitty-rust-swift-bindings = rustOutputs.purrSwiftBinds;
          clipkitty-rust-macos-universal = rustOutputs.purrMacUniversal;
          clipkitty-rust-ios-device = rustOutputs.purrIosDevice;
          clipkitty-rust-ios-simulator = rustOutputs.purrIosSim;
          clipkitty-rust-xcode-overlay = rustOutputs.purrXcodeOverlay;
        };

        # Apple intermediate stages are exposed for debugging. They're
        # declared here (not in `applePackageSet`) so `nix build .#all`
        # doesn't pull in a separate staged+generated copy per variant.
        appleIntermediateSet = {
          clipkitty-staged = applePackages.stagedSource;
          clipkitty-generated = applePackages.generatedSource;
        };
      in
      {
        # Public packages. The Darwin-only Apple targets live alongside the
        # Rust artifacts and legacy helpers so both `nix build .#clipkitty`
        # and `nix build .#clipkitty-rust-bridge` work without sniffing
        # around.
        packages =
          {
            bazelisk = pkgs.bazelisk;
          }
          // lib.optionalAttrs (asc != null) { inherit asc; }
          // lib.optionalAttrs isDarwin (
            rustPackageSet
            // appleIntermediateSet
            // applePackageSet
            // {
              default = applePackages.all;
              all = applePackages.all;
            }
          );

        checks =
          lib.optionalAttrs isDarwin {
            rust-tests = rustOutputs.rustTests;
            clipkitty-ios-smoke-build = applePackages.clipkittyIosSmokeTest;
          };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            rustToolchain
            pkgs.tuist
            pkgs.swiftlint
            pkgs.swiftformat
            pkgs.ffmpeg
            pkgs.age
            pkgs.cmark-gfm
            pkgs.cargo-deny
            keytap.packages.${system}.default
          ] ++ lib.optional (asc != null) asc;

          shellHook = ''
            export IN_NIX_SHELL=1

            # Install git hooks if not already installed
            if [ -d .git ] && [ ! -f .git/hooks/pre-commit ]; then
              ./Scripts/install-hooks.sh
            fi
          '';
        };
      }
    );
}
