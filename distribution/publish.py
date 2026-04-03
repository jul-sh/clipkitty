#!/usr/bin/env python3
"""Publish built .pkg/.ipa and all metadata/screenshots to App Store Connect.

Prerequisites:
  - ClipKitty.pkg (macOS) or ClipKittyiOS.ipa (iOS) exists at PROJECT_ROOT
  - keytap installed (via nix devShell), or AGE_SECRET_KEY env var
  - asc CLI installed (run distribution/install-deps.sh)

Usage:
  ./distribution/publish.py
  ./distribution/publish.py --platform ios --app-id 123456789
  ./distribution/publish.py --dry-run
  ./distribution/publish.py --metadata-only

If whatsNew cannot be set (e.g. first-ever submission), the script
automatically retries without release_notes.txt.
"""

import argparse
import base64
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
SECRETS_DIR = os.path.join(PROJECT_ROOT, "secrets")

PLATFORMS = {
    "macos": {
        "app_id": "6759137247",
        "altool_type": "osx",
        "asc_platform": "MAC_OS",
        "pkg_name": "ClipKitty.pkg",
        "metadata_dir_name": "metadata",
        "marketing_dir_name": "marketing",
        "screenshot_device_types": ["APP_DESKTOP"],
    },
    "ios": {
        "app_id": "6759137247",  # Same universal app as macOS
        "altool_type": "ios",
        "asc_platform": "IOS",
        "pkg_name": "ClipKittyiOS.ipa",
        "metadata_dir_name": "metadata",  # Shared metadata (same app listing)
        "marketing_dir_name": "marketing-ios",
        "screenshot_device_types": ["IPHONE_67"],
    },
}

LOCALE_MAP = {
    "en": "en-US", "es": "es-ES", "de": "de-DE", "fr": "fr-FR",
    "ja": "ja", "ko": "ko", "pt-BR": "pt-BR", "ru": "ru",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}


def run(cmd, *, check=True, capture=False, env=None):
    merged = {**os.environ, **(env or {})}
    r = subprocess.run(cmd, check=check, capture_output=capture, text=True, env=merged)
    return r


def decrypt_secret(name):
    r = subprocess.run(
        [os.path.join(SCRIPT_DIR, "read-secret.sh"), name],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit(f"Error decrypting {name}: {r.stderr.strip()}")
    return r.stdout.strip()



def read_asc_auth(field):
    r = subprocess.run(
        [os.path.join(SCRIPT_DIR, "asc-auth.sh"), field],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit(f"Error resolving ASC auth field {field}: {r.stderr.strip()}")
    return r.stdout.strip()


def resolve_app_id(platform_config, app_id_override):
    """Resolve the app ID: --app-id flag overrides platform config."""
    return app_id_override or platform_config["app_id"]


def main():
    parser = argparse.ArgumentParser(description="Publish to App Store Connect")
    parser.add_argument("--dry-run", action="store_true", help="Preview without uploading")
    parser.add_argument("--metadata-only", action="store_true", help="Skip binary upload")
    parser.add_argument("--version", help="Version string (e.g., 1.8.8) for auto-creating App Store version")
    parser.add_argument(
        "--platform", choices=["macos", "ios"], default="macos",
        help="Target platform (default: macos)",
    )
    parser.add_argument(
        "--app-id", default=None,
        help="Override the App Store Connect app ID",
    )
    args = parser.parse_args()

    platform_config = PLATFORMS[args.platform]
    app_id = resolve_app_id(platform_config, args.app_id)
    pkg_path = os.path.join(PROJECT_ROOT, platform_config["pkg_name"])
    metadata_dir = os.path.join(SCRIPT_DIR, platform_config["metadata_dir_name"])
    marketing_dir = os.path.join(PROJECT_ROOT, platform_config["marketing_dir_name"])

    # --- Validate prerequisites ---

    if not shutil.which("asc"):
        sys.exit("Error: asc CLI not found. Run: distribution/install-deps.sh")

    if not args.metadata_only and not os.path.isfile(pkg_path):
        sys.exit(f"Error: {pkg_path} not found. Run: make -C distribution appstore")

    # --- Decrypt secrets ---

    print("Decrypting secrets...")
    asc_key_id = read_asc_auth("key-id")
    asc_issuer_id = read_asc_auth("issuer-id")
    asc_private_key_b64 = read_asc_auth("private-key-b64")

    # --- Set up auth ---
    # xcrun altool requires the key at ~/.private_keys/AuthKey_<ID>.p8
    # (it ignores --apiKeyPath and only searches standard directories)

    altool_key_dir = os.path.expanduser("~/.private_keys")
    os.makedirs(altool_key_dir, exist_ok=True)
    altool_key_path = os.path.join(altool_key_dir, f"AuthKey_{asc_key_id}.p8")
    altool_key_existed = os.path.isfile(altool_key_path)

    # asc CLI uses ASC_PRIVATE_KEY_PATH (supports arbitrary paths)
    asc_key_fd, asc_key_path = tempfile.mkstemp()
    import_dir = None
    try:
        key_bytes = base64.b64decode(asc_private_key_b64)
        os.write(asc_key_fd, key_bytes)
        os.close(asc_key_fd)
        os.chmod(asc_key_path, 0o600)

        if not altool_key_existed:
            with open(altool_key_path, "wb") as f:
                f.write(key_bytes)
            os.chmod(altool_key_path, 0o600)

        asc_env = {
            "ASC_KEY_ID": asc_key_id,
            "ASC_ISSUER_ID": asc_issuer_id,
            "ASC_PRIVATE_KEY_PATH": asc_key_path,
        }
        os.environ.update(asc_env)

        print(f"Authenticated (key: {asc_key_id})")

        # --- Upload binary ---

        if not args.metadata_only:
            print("\n=== Uploading binary ===")
            if args.dry_run:
                print(f"[dry-run] Would upload: {pkg_path}")
            else:
                run([
                    "xcrun", "altool", "--upload-package", pkg_path,
                    "--type", platform_config["altool_type"],
                    "--apiKey", asc_key_id,
                    "--apiIssuer", asc_issuer_id,
                ])
                print("Binary uploaded.")

        # --- Upload metadata ---

        print("\n=== Uploading metadata ===")

        # Find the editable App Store version
        r = run(
            ["asc", "versions", "list",
             "--app", app_id, "--platform", platform_config["asc_platform"],
             "--state", "PREPARE_FOR_SUBMISSION"],
            capture=True, check=False,
        )
        if r.returncode != 0:
            sys.exit(f"Error listing versions: {r.stderr.strip()}")

        data = json.loads(r.stdout)
        versions = data.get("data", data) if isinstance(data, dict) else data
        version_id = None

        need_create = False
        if not versions:
            need_create = True
        elif args.version:
            existing_version = versions[0].get("attributes", {}).get("versionString", "")
            if existing_version != args.version:
                print(f"Existing PREPARE_FOR_SUBMISSION version is {existing_version}, but requested {args.version}.")
                need_create = True
            else:
                version_id = versions[0]["id"]

        if need_create:
            if args.version:
                print(f"Creating new App Store version {args.version}...")
                r = run(
                    ["asc", "versions", "create",
                     "--app", app_id, "--platform", platform_config["asc_platform"],
                     "--version", args.version, "--release-type", "MANUAL"],
                    capture=True, check=False,
                )
                if r.returncode == 0:
                    create_data = json.loads(r.stdout)
                    version_id = create_data.get("data", create_data).get("id") if isinstance(create_data, dict) else create_data.get("id")
                    print(f"Created version {args.version} (ID: {version_id})")
                else:
                    print(f"Warning: Could not create version {args.version}: {r.stderr.strip()}")
                    print("Skipping metadata and screenshot upload (binary was uploaded successfully).")
                    return
            else:
                if versions:
                    version_id = versions[0]["id"]
                else:
                    print("Warning: No App Store version in PREPARE_FOR_SUBMISSION state.")
                    print("Skipping metadata and screenshot upload (binary was uploaded successfully).")
                    print("Hint: Pass --version to auto-create a new version, or create one manually in App Store Connect.")
                    return

        print(f"Target version ID: {version_id}")

        # Assemble fastlane-style import directory (metadata only, no screenshots).
        # asc migrate import requires a screenshots/ dir to exist even if empty.
        import_dir = tempfile.mkdtemp()
        import_metadata = os.path.join(import_dir, "metadata")
        shutil.copytree(metadata_dir, import_metadata)
        os.makedirs(os.path.join(import_dir, "screenshots"), exist_ok=True)

        import_cmd = [
            "asc", "migrate", "import",
            "--app", app_id,
            "--version-id", version_id,
            "--fastlane-dir", import_dir,
        ]

        if args.dry_run:
            print(f"\n[dry-run] Would import metadata to version {version_id}:")
            print(f"  Metadata: {metadata_dir}")
            run(import_cmd + ["--dry-run"])
        else:
            r = run(import_cmd, check=False, capture=True)
            if r.returncode != 0 and "whatsNew" in r.stderr and "cannot be edited" in r.stderr:
                print("whatsNew rejected (first submission), retrying without release notes...")
                for root, _, files in os.walk(import_metadata):
                    for f in files:
                        if f == "release_notes.txt":
                            os.unlink(os.path.join(root, f))
                run(import_cmd)
            elif r.returncode != 0:
                print(r.stderr, file=sys.stderr)
                sys.exit(r.returncode)
            print("Metadata uploaded.")

        # --- Upload screenshots ---

        print("\n=== Uploading screenshots ===")

        # Get version localizations to map locale -> localization ID
        r = run(
            ["asc", "localizations", "list",
             "--version", version_id, "--paginate"],
            capture=True, check=False,
        )
        if r.returncode != 0:
            sys.exit(f"Error listing localizations: {r.stderr.strip()}")

        loc_data = json.loads(r.stdout)
        loc_list = loc_data.get("data", loc_data) if isinstance(loc_data, dict) else loc_data
        locale_to_loc_id = {}
        for loc in loc_list:
            locale = loc.get("attributes", {}).get("locale", "")
            locale_to_loc_id[locale] = loc["id"]

        screenshot_count = 0
        if os.path.isdir(marketing_dir):
            for entry in sorted(os.listdir(marketing_dir)):
                src_dir = os.path.join(marketing_dir, entry)
                if not os.path.isdir(src_dir):
                    continue
                asc_locale = LOCALE_MAP.get(entry)
                if not asc_locale:
                    continue
                loc_id = locale_to_loc_id.get(asc_locale)
                if not loc_id:
                    print(f"  Warning: no localization for {asc_locale}, skipping")
                    continue
                pngs = sorted(glob.glob(os.path.join(src_dir, "screenshot_*.png")))
                if not pngs:
                    continue

                for device_type in platform_config["screenshot_device_types"]:
                    # Delete existing screenshots before uploading new ones to avoid duplicates
                    print(f"  Deleting existing {device_type} screenshots for {asc_locale}...")
                    if args.dry_run:
                        print(f"    [dry-run] Would delete existing screenshots")
                    else:
                        r = run(
                            ["asc", "screenshots", "list",
                             "--version-localization", loc_id,
                             "--device-type", device_type],
                            capture=True, check=False,
                        )
                        if r.returncode == 0:
                            existing = json.loads(r.stdout)
                            existing_list = existing.get("data", existing) if isinstance(existing, dict) else existing
                            for screenshot in existing_list:
                                screenshot_id = screenshot.get("id")
                                if screenshot_id:
                                    run(
                                        ["asc", "screenshots", "delete",
                                         "--id", screenshot_id, "--confirm"],
                                        check=False,
                                    )

                    print(f"  Uploading {len(pngs)} {device_type} screenshots for {asc_locale}...")
                    if args.dry_run:
                        for png in pngs:
                            print(f"    [dry-run] {os.path.basename(png)}")
                    else:
                        for png in pngs:
                            run([
                                "asc", "screenshots", "upload",
                                "--version-localization", loc_id,
                                "--device-type", device_type,
                                "--path", png,
                            ])
                    screenshot_count += len(pngs)

        print(f"Total screenshots uploaded: {screenshot_count}")

        print("\n=== Publish complete ===")

    finally:
        os.unlink(asc_key_path)
        if not altool_key_existed and os.path.isfile(altool_key_path):
            os.unlink(altool_key_path)
        if import_dir and os.path.isdir(import_dir):
            shutil.rmtree(import_dir)


if __name__ == "__main__":
    main()
