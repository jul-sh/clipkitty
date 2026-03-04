use criterion::{criterion_group, criterion_main, Criterion};
use purr::database::Database;
use purr::models::StoredItem;
use purr::ClipboardStore;
use purr::ClipboardStoreApi;
use rand::Rng;
use std::path::PathBuf;

/// Number of items to generate
const NUM_ITEMS: usize = 150;

/// Minimum text size in bytes
const MIN_TEXT_SIZE: usize = 5_000;

/// Maximum text size in bytes
const MAX_TEXT_SIZE: usize = 100_000;

/// Number of extra-large items (50KB+)
const LARGE_ITEM_COUNT: usize = 20;

/// Sample code snippets for realistic content
const CODE_SNIPPETS: &[&str] = &[
    r#"
def process_data(input_data):
    """Process input data and return transformed result."""
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
"#,
    r#"
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
"#,
    r#"
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
"#,
    r#"
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
"#,
    r#"
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
"#,
];

/// Lorem ipsum words for filler text
const LOREM_WORDS: &[&str] = &[
    "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
    "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
    "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
    "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
    "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
    "velit", "esse", "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint",
    "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui", "officia",
    "deserunt", "mollit", "anim", "id", "est", "laborum",
];

/// Searchable keywords to sprinkle in
const KEYWORDS: &[&str] = &[
    "function", "error", "return", "import", "class", "async", "await", "struct",
    "enum", "interface", "protocol", "extension", "override", "private", "public",
];

/// Source apps for variety
const SOURCE_APPS: &[(&str, &str)] = &[
    ("Xcode", "com.apple.dt.Xcode"),
    ("VS Code", "com.microsoft.VSCode"),
    ("Terminal", "com.apple.Terminal"),
    ("Safari", "com.apple.Safari"),
    ("Notes", "com.apple.Notes"),
];

fn generate_text(target_size: usize) -> String {
    let mut rng = rand::thread_rng();
    let mut parts = Vec::new();
    let mut current_size = 0;

    // Start with some code snippets
    let num_snippets = rng.gen_range(2..=5);
    for _ in 0..num_snippets {
        let snippet = CODE_SNIPPETS[rng.gen_range(0..CODE_SNIPPETS.len())];
        parts.push(snippet.to_string());
        current_size += snippet.len();
    }

    // Fill with lorem-style text
    while current_size < target_size {
        let paragraph_len = rng.gen_range(50..=200);
        let mut words: Vec<&str> = (0..paragraph_len)
            .map(|_| LOREM_WORDS[rng.gen_range(0..LOREM_WORDS.len())])
            .collect();

        // Occasionally add searchable keywords
        if rng.gen_bool(0.3) {
            let insert_pos = rng.gen_range(0..words.len());
            words.insert(insert_pos, KEYWORDS[rng.gen_range(0..KEYWORDS.len())]);
        }

        let mut paragraph = words.join(" ");
        // Capitalize first letter
        if let Some(first) = paragraph.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
        paragraph.push_str(".\n\n");

        current_size += paragraph.len();
        parts.push(paragraph);
    }

    let result = parts.join("");
    result.chars().take(target_size).collect()
}

fn bench_db_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("benches/synthetic_perf.sqlite")
}

fn generate_perf_db(out_path: &std::path::Path) {
    eprintln!("Generating perf benchmark database ({} large items)...", NUM_ITEMS);

    if out_path.exists() {
        std::fs::remove_file(out_path).unwrap();
    }

    // Clean up any leftover tantivy index
    let tantivy_dir = out_path.parent().unwrap().join("tantivy_index_v3");
    if tantivy_dir.exists() {
        std::fs::remove_dir_all(&tantivy_dir).ok();
    }

    let db = Database::open(out_path.to_str().unwrap()).expect("Failed to create database");

    let mut rng = rand::thread_rng();
    let mut total_size = 0usize;

    for i in 0..NUM_ITEMS {
        let text_size = if i < LARGE_ITEM_COUNT {
            rng.gen_range(50_000..=MAX_TEXT_SIZE)
        } else {
            rng.gen_range(MIN_TEXT_SIZE..=50_000)
        };

        let text = generate_text(text_size);
        total_size += text.len();

        let (app_name, bundle_id) = SOURCE_APPS[rng.gen_range(0..SOURCE_APPS.len())];

        let item = StoredItem::new_text(
            text,
            Some(app_name.to_string()),
            Some(bundle_id.to_string()),
        );

        db.insert_item(&item).expect("Failed to insert item");
    }

    drop(db);

    eprintln!(
        "  Done: {} items, {:.2} MB total text",
        NUM_ITEMS,
        total_size as f64 / 1_048_576.0
    );
}

fn setup_store() -> ClipboardStore {
    let db_path = bench_db_path();
    if !db_path.exists() {
        generate_perf_db(&db_path);
    }
    ClipboardStore::new(db_path.to_str().unwrap().to_string())
        .expect("Failed to open perf benchmark database")
}

fn bench_search(c: &mut Criterion) {
    let store = setup_store();
    let rt = tokio::runtime::Runtime::new().unwrap();

    let queries = vec![
        ("short_2char", "hi"),
        ("medium_word", "hello"),
        ("long_word", "riverside"),
        ("multi_word", "hello world"),
        ("fuzzy_typo", "riversde"),
        ("trailing_space", "hello "),
        ("long_query", "error build failed due to dependency"),
    ];

    let mut group = c.benchmark_group("search_perf");
    group.sample_size(20);

    for (name, query) in queries {
        group.bench_function(name, |b| {
            b.iter(|| {
                rt.block_on(async {
                    store.search(query.to_string()).await.unwrap()
                })
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_search);
criterion_main!(benches);
