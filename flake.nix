{
  description = "ClipKitty Rust development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-parts.url = "github:hercules-ci/flake-parts";
    agenix-shell = {
      url = "github:aciceri/agenix-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, rust-overlay, flake-parts, agenix-shell, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      imports = [
        agenix-shell.flakeModules.default
      ];

      agenix-shell = {
        secrets = {
          ADMIN_TOKEN.file = ./secrets/ADMIN_TOKEN.age;
          APPSTORE_CERT_BASE64.file = ./secrets/APPSTORE_CERT_BASE64.age;
          APPSTORE_KEY_ID.file = ./secrets/APPSTORE_KEY_ID.age;
          HOMEBREW_TAP_TOKEN.file = ./secrets/HOMEBREW_TAP_TOKEN.age;
          MACOS_P12_BASE64.file = ./secrets/MACOS_P12_BASE64.age;
          MACOS_P12_PASSWORD.file = ./secrets/MACOS_P12_PASSWORD.age;
          MACOS_TEAM_ID.file = ./secrets/MACOS_TEAM_ID.age;
          NOTARY_ISSUER_ID.file = ./secrets/NOTARY_ISSUER_ID.age;
          NOTARY_KEY_BASE64.file = ./secrets/NOTARY_KEY_BASE64.age;
          NOTARY_KEY_ID.file = ./secrets/NOTARY_KEY_ID.age;
          P12_PASSWORD.file = ./secrets/P12_PASSWORD.age;
          PROVISION_PROFILE_BASE64.file = ./secrets/PROVISION_PROFILE_BASE64.age;
        };
        identityPaths = [
          "$HOME/.config/clipkitty/age-key.txt"
        ];
      };

      perSystem = { system, pkgs, config, ... }:
        let
          overlays = [ (import rust-overlay) ];
          rustPkgs = import nixpkgs {
            inherit system overlays;
          };

          # Rust toolchain with both ARM and x86_64 targets for universal binaries
          rustToolchain = rustPkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" "rust-std" ];
            targets = [ "aarch64-apple-darwin" "x86_64-apple-darwin" ];
          };
        in
        {
          devShells.default = pkgs.mkShell {
            buildInputs = [
              rustToolchain
              pkgs.age
            ];

            shellHook = ''
              export IN_NIX_SHELL=1

              # Bridge macOS Keychain → file for agenix-shell identity
              AGE_KEY_DIR="$HOME/.config/clipkitty"
              AGE_KEY_FILE="$AGE_KEY_DIR/age-key.txt"
              if [ ! -f "$AGE_KEY_FILE" ]; then
                echo "[clipkitty] Age key not found at $AGE_KEY_FILE"
                echo "[clipkitty] Attempting to extract from macOS Keychain..."
                if KEY=$(security find-generic-password -s "clipkitty-age-secret-key" -a "age" -w 2>/dev/null); then
                  mkdir -p "$AGE_KEY_DIR"
                  echo "$KEY" > "$AGE_KEY_FILE"
                  chmod 600 "$AGE_KEY_FILE"
                  echo "[clipkitty] Age key extracted to $AGE_KEY_FILE"
                else
                  echo "[clipkitty] WARNING: Could not retrieve age key from Keychain."
                  echo "[clipkitty] Secrets will not be available. To set up:"
                  echo "[clipkitty]   mkdir -p $AGE_KEY_DIR"
                  echo "[clipkitty]   echo 'AGE-SECRET-KEY-...' > $AGE_KEY_FILE"
                  echo "[clipkitty]   chmod 600 $AGE_KEY_FILE"
                fi
              fi

              # Decrypt secrets via agenix-shell (must be sourced to export env vars)
              source ${config.agenix-shell.installationScript}/bin/install-agenix-shell
            '';
          };
        };
    };
}
