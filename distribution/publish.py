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
        "screenshot_device_types": ["IPHONE_61"],
    },
}

LOCALE_MAP = {
    "en": "en-US", "es": "es-ES", "de": "de-DE", "fr": "fr-FR",
    "ja": "ja", "ko": "ko", "pt-BR": "pt-BR", "ru": "ru",
    "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant",
}

# Fastlane files that map to app-info (app-wide) fields rather than
# version-level fields. `asc migrate import` targets whichever app-info
# record asc's resolver picks, which isn't necessarily the editable one
# (apps in PENDING_RELEASE have a locked app-info alongside the
# READY_FOR_DISTRIBUTION editable one). We skip these files here and
# leave app-info updates to a manual flow.
APP_INFO_FILES = {"name.txt", "subtitle.txt", "privacy_url.txt"}


def run(cmd, *, check=True, capture=False, env=None):
    merged = {**os.environ, **(env or {})}
    r = subprocess.run(cmd, check=check, capture_output=capture, text=True, env=merged)
    return r


def purge_untargeted_screenshots(loc_id, target_device_types, *, dry_run):
    """Delete every screenshot in slots we aren't uploading to.

    ASC carries screenshots forward from previous versions, so when we change
    the device slot we publish to (e.g. IPHONE_67 -> IPHONE_61) the old set
    lingers alongside the new one. `--replace` on upload only wipes the
    *target* slot, so we have to wipe the non-target slots ourselves.

    screenshotDisplayType is prefixed with "APP_" in the list response
    (APP_IPHONE_61, APP_DESKTOP, ...) but the CLI accepts both prefixed and
    unprefixed names on upload, so normalize both sides for comparison.
    """
    target_set = {
        dt if dt.startswith("APP_") else f"APP_{dt}"
        for dt in target_device_types
    }
    r = run(
        ["asc", "screenshots", "list", "--version-localization", loc_id],
        capture=True, check=True,
    )
    payload = json.loads(r.stdout)
    for entry in payload.get("sets", []):
        display_type = entry.get("set", {}).get("attributes", {}).get("screenshotDisplayType")
        if display_type in target_set:
            continue
        screenshots = entry.get("screenshots", [])
        if not screenshots:
            continue
        print(f"    Purging {len(screenshots)} screenshot(s) from untargeted slot {display_type}")
        for screenshot in screenshots:
            screenshot_id = screenshot.get("id")
            if not screenshot_id:
                continue
            if dry_run:
                print(f"      [dry-run] Would delete {screenshot_id}")
            else:
                run(
                    ["asc", "screenshots", "delete",
                     "--id", screenshot_id, "--confirm"],
                    check=False,
                )


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


def asc_json(cmd):
    """Run an asc command that returns JSON; exit on failure."""
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"Error running {' '.join(cmd)}: {r.stderr.strip()}")
    return json.loads(r.stdout)


def unwrap_data(payload):
    """Unwrap `{data: ...}` envelopes that asc uses for some commands."""
    if isinstance(payload, dict) and "data" in payload:
        return payload["data"]
    return payload


def resolve_target_version(app_id, asc_platform, requested_version):
    """Return the version_id of the App Store draft to write metadata to.

    ASC allows exactly one editable (PREPARE_FOR_SUBMISSION) draft per
    platform, so "find or create" is a deterministic state machine:

      1. If a draft exists, reuse it. Rename it to match `requested_version`
         if it doesn't already; on rename failure fall through with the
         existing version string (best-effort — uploading metadata to a
         draft with a stale versionString is still better than skipping
         metadata entirely).
      2. If no draft exists, create one with `requested_version`. This
         requires `requested_version` to be set.

    Deletion of the existing draft is never attempted. It fails once a
    build has been attached to the draft (which happens earlier in every
    CI run, via `altool --upload-package`), and the subsequent `create`
    would fail too because the old draft still exists — leaving the
    publish flow with no version to write metadata to.
    """
    versions = unwrap_data(asc_json([
        "asc", "versions", "list",
        "--app", app_id, "--platform", asc_platform,
        "--state", "PREPARE_FOR_SUBMISSION",
    ]))

    if versions:
        version_id = versions[0]["id"]
        existing_version = versions[0].get("attributes", {}).get("versionString", "")
        if requested_version and existing_version != requested_version:
            print(f"Retargeting PREPARE_FOR_SUBMISSION draft {existing_version} -> {requested_version} (ID: {version_id})...")
            r = subprocess.run(
                ["asc", "versions", "update",
                 "--version-id", version_id, "--version", requested_version],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                print(f"Warning: Could not rename draft: {r.stderr.strip()}")
                print(f"Proceeding with existing draft version {existing_version}.")
        return version_id

    if not requested_version:
        sys.exit(
            "Error: No App Store version in PREPARE_FOR_SUBMISSION state and "
            "no --version passed. Pass --version to auto-create one, or "
            "create a draft manually in App Store Connect."
        )

    print(f"Creating new App Store version {requested_version}...")
    created = unwrap_data(asc_json([
        "asc", "versions", "create",
        "--app", app_id, "--platform", asc_platform,
        "--version", requested_version, "--release-type", "MANUAL",
    ]))
    version_id = created["id"] if isinstance(created, dict) else created[0]["id"]
    print(f"Created version {requested_version} (ID: {version_id})")
    return version_id


def build_import_dir(metadata_dir):
    """Stage a fastlane-shaped import tree for `asc migrate import`.

    - Copies `metadata_dir` into `<tmp>/metadata/`.
    - Strips files mapped to app-info fields so the import targets only
      version-level fields (see APP_INFO_FILES).
    - Creates an empty `<tmp>/screenshots/` (asc requires it to exist).

    Returns the temp dir path; caller is responsible for cleanup.
    """
    import_dir = tempfile.mkdtemp()
    import_metadata = os.path.join(import_dir, "metadata")
    shutil.copytree(metadata_dir, import_metadata)
    os.makedirs(os.path.join(import_dir, "screenshots"), exist_ok=True)

    stripped = 0
    for root, _, files in os.walk(import_metadata):
        for f in files:
            if f in APP_INFO_FILES:
                os.unlink(os.path.join(root, f))
                stripped += 1
    if stripped:
        print(
            f"Skipping {stripped} app-info file(s) "
            f"({', '.join(sorted(APP_INFO_FILES))}); "
            "these must be updated manually in App Store Connect."
        )
    return import_dir


def strip_release_notes(import_metadata):
    removed = 0
    for root, _, files in os.walk(import_metadata):
        for f in files:
            if f == "release_notes.txt":
                os.unlink(os.path.join(root, f))
                removed += 1
    return removed


def upload_version_metadata(app_id, version_id, metadata_dir, dry_run):
    """Import version-level metadata for `version_id` via `asc migrate import`.

    Handles the first-submission case where `whatsNew` can't be edited by
    retrying once without release_notes.txt. Every asc invocation here uses
    `check=False` so we surface the real stderr on final failure instead of
    crashing with a CalledProcessError traceback.
    """
    import_dir = build_import_dir(metadata_dir)
    import_metadata = os.path.join(import_dir, "metadata")
    try:
        import_cmd = [
            "asc", "migrate", "import",
            "--app", app_id,
            "--version-id", version_id,
            "--fastlane-dir", import_dir,
        ]

        if dry_run:
            print(f"\n[dry-run] Would import metadata to version {version_id}:")
            print(f"  Metadata: {metadata_dir}")
            run(import_cmd + ["--dry-run"], check=False)
            return

        r = run(import_cmd, check=False, capture=True)
        if r.returncode != 0 and "whatsNew" in r.stderr and "cannot be edited" in r.stderr:
            print("whatsNew rejected (first submission), retrying without release notes...")
            removed = strip_release_notes(import_metadata)
            print(f"  Removed {removed} release_notes.txt file(s) from import set.")
            r = run(import_cmd, check=False, capture=True)

        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            sys.exit(f"Error: asc migrate import failed (exit {r.returncode}).")
        print("Metadata uploaded.")
    finally:
        shutil.rmtree(import_dir, ignore_errors=True)


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
        sys.exit("Error: asc CLI not found. Enter the Nix dev shell (nix develop) or run: nix profile install .#asc")

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
                # altool exits 0 on validation/network failures but prints
                # "Failed to upload package." — capture and inspect output.
                r = run([
                    "xcrun", "altool", "--upload-package", pkg_path,
                    "--type", platform_config["altool_type"],
                    "--apiKey", asc_key_id,
                    "--apiIssuer", asc_issuer_id,
                ], check=False, capture=True)
                print(r.stdout, end="")
                if r.stderr:
                    print(r.stderr, end="", file=sys.stderr)
                combined = (r.stdout or "") + (r.stderr or "")
                succeeded = "UPLOAD SUCCEEDED" in combined
                failed = (
                    r.returncode != 0
                    or "Failed to upload package." in combined
                    or " ERROR: " in combined
                )
                if failed or not succeeded:
                    sys.exit(f"Binary upload failed (altool exit {r.returncode}).")
                print("Binary uploaded.")

        # --- Upload metadata ---

        print("\n=== Uploading metadata ===")

        version_id = resolve_target_version(
            app_id, platform_config["asc_platform"], args.version,
        )
        print(f"Target version ID: {version_id}")

        upload_version_metadata(app_id, version_id, metadata_dir, args.dry_run)

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
        if not os.path.isdir(marketing_dir):
            print(f"  Warning: marketing directory not found: {marketing_dir}")
            print(f"  No screenshots will be uploaded for {args.platform}.")
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
                    print(f"  Warning: no screenshots found in {src_dir}")
                    continue

                purge_untargeted_screenshots(
                    loc_id,
                    platform_config["screenshot_device_types"],
                    dry_run=args.dry_run,
                )

                for device_type in platform_config["screenshot_device_types"]:
                    # --replace deletes every existing screenshot in the target set
                    # before uploading, so stale screenshots from prior publishes
                    # don't pile up alongside the new ones in the ASC listing.
                    print(f"  Uploading {len(pngs)} {device_type} screenshots for {asc_locale} (replacing existing)...")
                    if args.dry_run:
                        print(f"    [dry-run] Would replace and upload {src_dir}")
                    else:
                        run([
                            "asc", "screenshots", "upload",
                            "--version-localization", loc_id,
                            "--device-type", device_type,
                            "--path", src_dir,
                            "--replace",
                        ])
                    screenshot_count += len(pngs)

        print(f"Total screenshots uploaded: {screenshot_count}")

        print("\n=== Publish complete ===")

    finally:
        os.unlink(asc_key_path)
        if not altool_key_existed and os.path.isfile(altool_key_path):
            os.unlink(altool_key_path)


if __name__ == "__main__":
    main()
