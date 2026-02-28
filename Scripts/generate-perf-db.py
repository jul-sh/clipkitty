#!/usr/bin/env python3
"""
Generate a performance test database with large text items.

This creates a SQLite database seeded with items that replicate the conditions
that caused main thread hangs during rapid search typing:
- Many items (100+)
- Items with long text content (10KB-100KB)
- Varied content to test search/highlight performance

Usage:
    ./Scripts/generate-perf-db.py [output_path]

Default output: distribution/SyntheticData_perf.sqlite
"""

import sqlite3
import sys
import os
import random
import string
from datetime import datetime, timedelta
from pathlib import Path

# Configuration
NUM_ITEMS = 150
MIN_TEXT_SIZE = 5_000      # 5KB minimum
MAX_TEXT_SIZE = 100_000    # 100KB maximum
LARGE_ITEM_COUNT = 20      # Number of extra-large items (50KB+)

# Sample code snippets to make content realistic and searchable
CODE_SNIPPETS = [
    """
def process_data(input_data):
    \"\"\"Process input data and return transformed result.\"\"\"
    if not input_data:
        return None

    result = []
    for item in input_data:
        try:
            transformed = transform_item(item)
            result.append(transformed)
        except ValueError as e:
            print(f"Error processing item: {e}")
            continue

    return result
""",
    """
class DataProcessor:
    def __init__(self, config):
        self.config = config
        self.cache = {}

    def process(self, data):
        cache_key = self._compute_key(data)
        if cache_key in self.cache:
            return self.cache[cache_key]

        result = self._do_process(data)
        self.cache[cache_key] = result
        return result
""",
    """
import SwiftUI

struct ContentView: View {
    @State private var searchText = ""
    @State private var items: [Item] = []

    var body: some View {
        VStack {
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredItems) { item in
                ItemRow(item: item)
            }
        }
    }

    var filteredItems: [Item] {
        if searchText.isEmpty {
            return items
        }
        return items.filter { $0.matches(searchText) }
    }
}
""",
    """
async function fetchData(url: string): Promise<Data> {
    try {
        const response = await fetch(url, {
            method: 'GET',
            headers: {
                'Content-Type': 'application/json',
            },
        });

        if (!response.ok) {
            throw new Error(`HTTP error: ${response.status}`);
        }

        const data = await response.json();
        return processResponse(data);
    } catch (error) {
        console.error('Fetch failed:', error);
        throw error;
    }
}
""",
    """
func handleError(_ error: Error) -> ErrorResponse {
    switch error {
    case let networkError as NetworkError:
        return .network(message: networkError.localizedDescription)
    case let validationError as ValidationError:
        return .validation(fields: validationError.invalidFields)
    case let authError as AuthenticationError:
        return .unauthorized(reason: authError.reason)
    default:
        return .unknown(underlying: error)
    }
}
""",
]

LOREM_WORDS = """
lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor
incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud
exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute
irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat
nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa qui
officia deserunt mollit anim id est laborum
""".split()


def generate_text(target_size: int) -> str:
    """Generate text content of approximately target_size bytes."""
    parts = []
    current_size = 0

    # Start with some code snippets
    num_snippets = random.randint(2, 5)
    for _ in range(num_snippets):
        snippet = random.choice(CODE_SNIPPETS)
        parts.append(snippet)
        current_size += len(snippet)

    # Fill with lorem-style text
    while current_size < target_size:
        paragraph_len = random.randint(50, 200)
        words = [random.choice(LOREM_WORDS) for _ in range(paragraph_len)]

        # Occasionally add searchable keywords
        if random.random() < 0.3:
            keywords = ["function", "error", "return", "import", "class", "async", "await"]
            insert_pos = random.randint(0, len(words) - 1)
            words.insert(insert_pos, random.choice(keywords))

        paragraph = " ".join(words).capitalize() + ".\n\n"
        parts.append(paragraph)
        current_size += len(paragraph)

    return "".join(parts)[:target_size]


def generate_snippet(text: str, max_len: int = 200) -> str:
    """Generate a snippet from text content."""
    # Take first non-empty line
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and not stripped.startswith("//"):
            if len(stripped) > max_len:
                return stripped[:max_len - 3] + "..."
            return stripped
    return text[:max_len]


def create_database(output_path: str):
    """Create the performance test database."""
    # Remove existing file
    if os.path.exists(output_path):
        os.remove(output_path)

    conn = sqlite3.connect(output_path)
    cursor = conn.cursor()

    # Create schema (matching ClipKitty's actual schema)
    cursor.executescript("""
        CREATE TABLE IF NOT EXISTS items (
            item_id INTEGER PRIMARY KEY AUTOINCREMENT,
            text_content TEXT,
            image_data BLOB,
            file_paths TEXT,
            link_url TEXT,
            created_at TEXT NOT NULL,
            source_app TEXT,
            source_app_bundle_id TEXT,
            content_type TEXT NOT NULL DEFAULT 'text',
            link_metadata_state TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_content_type ON items(content_type);
    """)

    # Generate items
    base_time = datetime.now()
    apps = [
        ("Xcode", "com.apple.dt.Xcode"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Terminal", "com.apple.Terminal"),
        ("Safari", "com.apple.Safari"),
        ("Notes", "com.apple.Notes"),
    ]

    print(f"Generating {NUM_ITEMS} items...")

    for i in range(NUM_ITEMS):
        # Determine text size (some items are extra large)
        if i < LARGE_ITEM_COUNT:
            text_size = random.randint(50_000, MAX_TEXT_SIZE)
        else:
            text_size = random.randint(MIN_TEXT_SIZE, 50_000)

        text_content = generate_text(text_size)
        created_at = (base_time - timedelta(hours=i)).isoformat()
        app_name, bundle_id = random.choice(apps)

        cursor.execute("""
            INSERT INTO items (text_content, created_at, source_app, source_app_bundle_id, content_type)
            VALUES (?, ?, ?, ?, 'text')
        """, (text_content, created_at, app_name, bundle_id))

        if (i + 1) % 25 == 0:
            print(f"  Generated {i + 1}/{NUM_ITEMS} items...")

    conn.commit()

    # Print stats
    cursor.execute("SELECT COUNT(*), SUM(LENGTH(text_content)), AVG(LENGTH(text_content)), MAX(LENGTH(text_content)) FROM items")
    count, total_size, avg_size, max_size = cursor.fetchone()
    print(f"""
Database created: {output_path}
  Items: {count}
  Total text size: {total_size / 1024 / 1024:.2f} MB
  Average item size: {avg_size / 1024:.1f} KB
  Largest item: {max_size / 1024:.1f} KB
""")

    conn.close()


def main():
    script_dir = Path(__file__).parent.parent
    default_output = script_dir / "distribution" / "SyntheticData_perf.sqlite"

    output_path = sys.argv[1] if len(sys.argv) > 1 else str(default_output)

    # Ensure output directory exists
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    create_database(output_path)


if __name__ == "__main__":
    main()
