#!/usr/bin/env python3
"""
Inject images from distribution/images/ into a SQLite database for a specific locale.
Used at screenshot time to populate the DB with localized image descriptions.

Usage: ./inject-images.py <db_path> <locale>
Example: ./inject-images.py SyntheticData.sqlite en
"""

import sqlite3
import sys
import os
import csv
import hashlib
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

    if not images_dir.exists():
        print(f"Error: images directory not found at {images_dir}")
        sys.exit(1)

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

    # Get current timestamp
    cursor.execute("SELECT datetime('now')")
    now = cursor.fetchone()[0]

    # Ensure image_items table has locale column
    cursor.execute("PRAGMA table_info(image_items)")
    columns = [col[1] for col in cursor.fetchall()]
    if 'locale' not in columns:
        cursor.execute("ALTER TABLE image_items ADD COLUMN locale TEXT DEFAULT 'en'")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_image_locale ON image_items(locale)")

    # Find all HEIC images (skip thumbnails)
    heic_files = sorted(images_dir.glob("*.heic"))

    inserted = 0
    for heic_path in heic_files:
        # Find matching thumbnail
        thumb_path = heic_path.with_suffix("").with_name(heic_path.stem + "_thumb.webp")

        # Get the English description from manifest or filename
        # The filename format is: keywords_hash.heic
        stem = heic_path.stem
        # Remove hash suffix (last 9 chars: _xxxxxxxx)
        if '_' in stem and len(stem.split('_')[-1]) == 8:
            keywords_part = '_'.join(stem.split('_')[:-1])
        else:
            keywords_part = stem

        # Convert filename back to keywords format (approximate)
        # We need to match against the manifest or CSV
        image_data = heic_path.read_bytes()
        thumbnail_data = thumb_path.read_bytes() if thumb_path.exists() else None

        # Find matching English description by hash
        image_hash = hashlib.md5(image_data).hexdigest()[:8]

        # Match by looking for the hash in the filename
        en_description = None
        for en_kw in locale_keywords.keys():
            # Generate expected filename from English keywords
            kw_parts = en_kw.split(', ')[:3]
            expected_prefix = '_'.join(kw_parts).replace(' ', '_').replace('/', '_')[:50]
            if heic_path.name.startswith(expected_prefix):
                en_description = en_kw
                break

        if not en_description:
            print(f"Warning: Could not match {heic_path.name} to keywords CSV")
            continue

        # Get localized description
        description = locale_keywords.get(en_description, en_description)

        # Determine source app from keywords (simple heuristic)
        if any(x in en_description for x in ['painting', 'woodblock', 'print', 'illustration']):
            source_app = "Safari" if 'impressionist' in en_description else "Photos"
            bundle_id = "com.apple.Safari" if source_app == "Safari" else "com.apple.Photos"
        else:
            source_app = "Photos" if 'photograph' in en_description else "Safari"
            bundle_id = "com.apple.Photos" if source_app == "Photos" else "com.apple.Safari"

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

        # Insert into items table
        cursor.execute("""
            INSERT INTO items (contentType, contentHash, content, timestamp, sourceApp, sourceAppBundleId, thumbnail)
            VALUES ('image', ?, ?, ?, ?, ?, ?)
        """, (content_hash, description, now, source_app, bundle_id, thumbnail_data))

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
