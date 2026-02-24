{
  description = "ClipKitty Rust development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
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
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            rustToolchain
            pkgs.swiftlint
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
