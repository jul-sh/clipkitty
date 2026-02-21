#!/usr/bin/env python3
"""
Inject images from distribution/images/ into a SQLite database for a specific locale.
Used at screenshot time to populate the DB with localized image descriptions.

Usage: ./inject-images.py <db_path> <locale>
Example: ./inject-images.py SyntheticData.sqlite en
"""

import sqlite3
import sys
import csv
import json
from datetime import datetime, timedelta
from pathlib import Path

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <db_path> <locale>")
        sys.exit(1)

    db_path = sys.argv[1]
    locale = sys.argv[2]

    script_dir = Path(__file__).parent
    images_dir = script_dir / "images"
    keywords_csv = script_dir / "image_keywords.csv"
    manifest_path = images_dir / "manifest.json"

    if not images_dir.exists():
        print(f"Error: images directory not found at {images_dir}")
        sys.exit(1)

    if not manifest_path.exists():
        print(f"Error: manifest.json not found at {manifest_path}")
        sys.exit(1)

    # Load manifest for image metadata (source_app, bundle_id, offset_seconds)
    with open(manifest_path, 'r', encoding='utf-8') as f:
        manifest = json.load(f)

    # Build lookup by English description
    manifest_by_desc = {item['description_en']: item for item in manifest}

    # Load localized keywords from CSV
    locale_keywords = {}  # description_en -> localized_description
    locale_col_map = {
        "en": 1, "es": 2, "fr": 3, "de": 4, "ja": 5,
        "ko": 6, "zh-Hans": 7, "zh-Hant": 8, "pt-BR": 9, "ru": 10
    }

    if locale not in locale_col_map:
        print(f"Error: Unknown locale '{locale}'. Valid: {list(locale_col_map.keys())}")
        sys.exit(1)

    col_idx = locale_col_map[locale]

    with open(keywords_csv, 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        next(reader)  # Skip header
        for row in reader:
            if len(row) > col_idx:
                # Map English keywords to localized keywords
                en_keywords = row[1]  # English is column 1
                localized_keywords = row[col_idx]
                locale_keywords[en_keywords] = localized_keywords

    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Get current timestamp as base
    now = datetime.now()

    # Ensure image_items table has locale column
    cursor.execute("PRAGMA table_info(image_items)")
    columns = [col[1] for col in cursor.fetchall()]
    if 'locale' not in columns:
        cursor.execute("ALTER TABLE image_items ADD COLUMN locale TEXT DEFAULT 'en'")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_image_locale ON image_items(locale)")

    inserted = 0

    # Process each image from the manifest
    for item in manifest:
        heic_path = images_dir / item['file']
        thumb_path = images_dir / item['thumbnail']

        if not heic_path.exists():
            print(f"Warning: Image file not found: {heic_path}")
            continue

        en_description = item['description_en']
        source_app = item['source_app']
        bundle_id = item['bundle_id']
        offset_seconds = item.get('offset_seconds', -3600)  # Default 1 hour ago

        # Get localized description
        description = locale_keywords.get(en_description, en_description)

        # Calculate timestamp with offset (images should appear older than text items)
        timestamp = now + timedelta(seconds=offset_seconds)
        timestamp_str = timestamp.strftime('%Y-%m-%d %H:%M:%S')

        # Read image data
        image_data = heic_path.read_bytes()
        thumbnail_data = thumb_path.read_bytes() if thumb_path.exists() else None

        # Create content hash
        hash_input = f"{description}{len(image_data)}{locale}"
        content_hash = str(hash(hash_input) & 0xFFFFFFFFFFFFFFFF)

        # Check if already exists
        cursor.execute(
            "SELECT 1 FROM image_items WHERE description = ? AND locale = ? LIMIT 1",
            (description, locale)
        )
        if cursor.fetchone():
            continue

        # Insert into items table with proper timestamp
        cursor.execute("""
            INSERT INTO items (contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail)
            VALUES ('image', ?, ?, ?, ?, ?, ?)
        """, (content_hash, description, timestamp_str, source_app, bundle_id, thumbnail_data))

        item_id = cursor.lastrowid

        # Insert into image_items table
        cursor.execute("""
            INSERT INTO image_items (itemId, data, description, locale)
            VALUES (?, ?, ?, ?)
        """, (item_id, image_data, description, locale))

        inserted += 1

    conn.commit()
    conn.close()

    print(f"Injected {inserted} images for locale '{locale}' into {db_path}")

if __name__ == "__main__":
    main()
