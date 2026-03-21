{
  description = "ClipKitty Rust development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
    tapkey.url = "github:jul-sh/tapkey";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, tapkey, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Rust toolchain with both ARM and x86_64 targets for universal binaries
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-std" ];
          targets = [ "aarch64-apple-darwin" "x86_64-apple-darwin" ];
        };

        # App Store Connect CLI (pre-built binary)
        asc = let
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
          }.${system} or (throw "asc: unsupported system ${system}");
        in pkgs.runCommand "asc-${version}" {} ''
          mkdir -p $out/bin
          cp ${src} $out/bin/asc
          chmod +x $out/bin/asc
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            rustToolchain
            pkgs.swiftlint
            pkgs.swiftformat
            asc
          ] ++ pkgs.lib.optionals (tapkey.packages ? ${system}) [
            tapkey.packages.${system}.default
          ];

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
