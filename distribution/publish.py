#!/usr/bin/env python3
"""Publish built .pkg and all metadata/screenshots to App Store Connect.

Prerequisites:
  - ClipKitty.pkg exists at PROJECT_ROOT (run `make -C distribution appstore` first)
  - AGE_SECRET_KEY env var set (the age private key string)
  - asc CLI installed (run distribution/install-deps.sh)

Usage:
  AGE_SECRET_KEY="AGE-SECRET-KEY-..." ./distribution/publish.py
  AGE_SECRET_KEY="AGE-SECRET-KEY-..." ./distribution/publish.py --dry-run
  AGE_SECRET_KEY="AGE-SECRET-KEY-..." ./distribution/publish.py --metadata-only
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

APP_ID = "6759137247"
PKG_PATH = os.path.join(PROJECT_ROOT, "ClipKitty.pkg")
METADATA_DIR = os.path.join(SCRIPT_DIR, "metadata")
MARKETING_DIR = os.path.join(PROJECT_ROOT, "marketing")

LOCALE_MAP = {
    "en": "en-US", "es": "es-ES", "de": "de-DE", "fr": "fr-FR",
    "ja": "ja", "ko": "ko", "pt-BR": "pt-BR", "ru": "ru",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}


def run(cmd, *, check=True, capture=False, env=None):
    merged = {**os.environ, **(env or {})}
    r = subprocess.run(cmd, check=check, capture_output=capture, text=True, env=merged)
    return r


def decrypt_secret(name, age_key):
    path = os.path.join(SECRETS_DIR, f"{name}.age")
    if not os.path.isfile(path):
        sys.exit(f"Error: Secret file not found: {path}")
    r = subprocess.run(
        ["age", "-d", "-i", "-", path],
        input=age_key, capture_output=True, text=True,
    )
    if r.returncode != 0:
        sys.exit(f"Error decrypting {name}: {r.stderr.strip()}")
    return r.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description="Publish to App Store Connect")
    parser.add_argument("--dry-run", action="store_true", help="Preview without uploading")
    parser.add_argument("--metadata-only", action="store_true", help="Skip binary upload")
    parser.add_argument("--skip-release-notes", action="store_true",
                        help="Exclude release_notes.txt (required for first-ever App Store submission)")
    args = parser.parse_args()

    # --- Validate prerequisites ---

    age_key = os.environ.get("AGE_SECRET_KEY", "")
    if not age_key:
        sys.exit("Error: AGE_SECRET_KEY environment variable is required.\n"
                 "  export AGE_SECRET_KEY='AGE-SECRET-KEY-...'")

    if not shutil.which("asc"):
        sys.exit("Error: asc CLI not found. Run: distribution/install-deps.sh")

    if not args.metadata_only and not os.path.isfile(PKG_PATH):
        sys.exit(f"Error: {PKG_PATH} not found. Run: make -C distribution appstore")

    # --- Decrypt secrets ---

    print("Decrypting secrets...")
    asc_key_id = decrypt_secret("APPSTORE_KEY_ID", age_key)
    asc_issuer_id = decrypt_secret("NOTARY_ISSUER_ID", age_key)
    asc_private_key_b64 = decrypt_secret("NOTARY_KEY_BASE64", age_key)

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
                print(f"[dry-run] Would upload: {PKG_PATH}")
            else:
                run([
                    "xcrun", "altool", "--upload-package", PKG_PATH,
                    "--type", "osx",
                    "--apiKey", asc_key_id,
                    "--apiIssuer", asc_issuer_id,
                ])
                print("Binary uploaded.")

        # --- Upload metadata & screenshots ---

        print("\n=== Uploading metadata & screenshots ===")

        # Find the editable App Store version
        r = run(
            ["asc", "versions", "list",
             "--app", APP_ID, "--platform", "MAC_OS",
             "--state", "PREPARE_FOR_SUBMISSION"],
            capture=True, check=False,
        )
        if r.returncode != 0:
            sys.exit(f"Error listing versions: {r.stderr.strip()}")

        data = json.loads(r.stdout)
        versions = data.get("data", data) if isinstance(data, dict) else data
        if not versions:
            sys.exit("Error: No App Store version in PREPARE_FOR_SUBMISSION state.\n"
                     "Create a new version in App Store Connect first.")
        version_id = versions[0]["id"]
        print(f"Target version ID: {version_id}")

        # Assemble fastlane-style import directory (copy metadata so we can filter files)
        import_dir = tempfile.mkdtemp()
        import_metadata = os.path.join(import_dir, "metadata")
        shutil.copytree(METADATA_DIR, import_metadata)
        if args.skip_release_notes:
            for root, _, files in os.walk(import_metadata):
                for f in files:
                    if f == "release_notes.txt":
                        os.unlink(os.path.join(root, f))
            print("Skipping release_notes.txt (first submission)")
        screenshots_dir = os.path.join(import_dir, "screenshots")
        os.makedirs(screenshots_dir)

        screenshot_count = 0
        if os.path.isdir(MARKETING_DIR):
            for entry in sorted(os.listdir(MARKETING_DIR)):
                src_dir = os.path.join(MARKETING_DIR, entry)
                if not os.path.isdir(src_dir):
                    continue
                asc_locale = LOCALE_MAP.get(entry)
                if not asc_locale:
                    continue
                pngs = sorted(glob.glob(os.path.join(src_dir, "screenshot_*.png")))
                if not pngs:
                    continue
                dest = os.path.join(screenshots_dir, asc_locale)
                os.makedirs(dest)
                for png in pngs:
                    shutil.copy2(png, dest)
                screenshot_count += len(pngs)
                print(f"  Screenshots: {entry} -> {asc_locale} ({len(pngs)} files)")

        print(f"Total screenshots: {screenshot_count}")

        import_cmd = [
            "asc", "migrate", "import",
            "--app", APP_ID,
            "--version-id", version_id,
            "--fastlane-dir", import_dir,
        ]

        if args.dry_run:
            print(f"\n[dry-run] Would import to version {version_id}:")
            print(f"  Metadata: {METADATA_DIR}")
            print(f"  Screenshots: {screenshot_count} files")
            run(import_cmd + ["--dry-run"])
        else:
            run(import_cmd)
            print("Metadata and screenshots uploaded.")

        print("\n=== Publish complete ===")

    finally:
        os.unlink(asc_key_path)
        if not altool_key_existed and os.path.isfile(altool_key_path):
            os.unlink(altool_key_path)
        if import_dir and os.path.isdir(import_dir):
            shutil.rmtree(import_dir)


if __name__ == "__main__":
    main()
