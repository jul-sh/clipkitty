use crate::database::Database;
use crate::indexer::Indexer;
use crate::models::StoredItem;
use anyhow::Result;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::fs;
use std::path::{Path, PathBuf};

const FIXTURE_SEED: u64 = 0xC11C_1771_0000_0001;
const TOTAL_TEXT_ITEMS: usize = 1_094;
const TOTAL_LINK_ITEMS: usize = 165;
const TOTAL_IMAGE_ITEMS: usize = 9;
const TOTAL_FILE_ITEMS: usize = 1;
const TINY_TEXT_ITEMS: usize = 915;
const SMALL_TEXT_ITEMS: usize = 134;
const MEDIUM_TEXT_ITEMS: usize = 38;
const LARGE_TEXT_TARGET_SIZES: [usize; 5] = [180_000, 260_000, 390_000, 620_000, 950_000];
const HUGE_TEXT_TARGET_SIZES: [usize; 2] = [18_500_000, 50_700_000];

const SOURCE_APPS: &[(&str, &str)] = &[
    ("Xcode", "com.apple.dt.Xcode"),
    ("VS Code", "com.microsoft.VSCode"),
    ("Terminal", "com.apple.Terminal"),
    ("Safari", "com.apple.Safari"),
    ("Notes", "com.apple.Notes"),
    ("Arc", "company.thebrowser.Browser"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"),
];

const CODE_SNIPPETS: &[&str] = &[
    "fn render_search_results(query: &str, items: &[Item]) -> Vec<Row> {\n    items.iter().filter(|item| item.matches(query)).map(Row::from).collect()\n}\n",
    "async function fetchData(url) {\n  const response = await fetch(url);\n  if (!response.ok) throw new Error(`request failed: ${response.status}`);\n  return response.json();\n}\n",
    "class SearchIndex {\n    func lookup(_ query: String) -> [SearchHit] {\n        guard !query.isEmpty else { return [] }\n        return storage.filter { $0.contains(query) }\n    }\n}\n",
    "def process_error(error, context):\n    if error is None:\n        return context\n    logger.error('process failure: %s', error)\n    return {'error': str(error), 'context': context}\n",
    "struct ResultRow: Identifiable {\n    let id: Int64\n    let snippet: String\n    let source: String\n}\n",
    "interface SearchResult {\n  itemId: number;\n  snippet: string;\n  score: number;\n  sourceApp?: string;\n}\n",
];

const NOTE_SNIPPETS: &[&str] = &[
    "Remember to return the cache key after the function finishes.",
    "Class hierarchy still needs cleanup before the next release.",
    "Search error only reproduces when the result set is very large.",
    "Lorem ipsum notes were copied here while testing the snippet pipeline.",
    "Need to compare prefix ranking against exact phrase ranking.",
    "Follow up on the import path override in the staging build.",
];

const URL_HOSTS: &[&str] = &[
    "docs.example.com",
    "api.example.com",
    "developer.apple.com",
    "news.ycombinator.com",
    "github.com",
    "linear.app",
    "notion.so",
];

const FILE_EXTENSIONS: &[(&str, &str)] = &[
    ("rs", "public.rust-source"),
    ("swift", "public.swift-source"),
    ("ts", "public.typescript-source"),
    ("md", "net.daringfireball.markdown"),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TextSizeClass {
    Tiny,
    Small,
    Medium,
    Large,
    Huge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FixtureSpec {
    Text {
        size_class: TextSizeClass,
        target_size: usize,
    },
    Link {
        target_size: usize,
    },
    Image {
        target_size: usize,
    },
    File {
        target_size: usize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyntheticBenchSummary {
    pub total_items: usize,
    pub total_text_bytes: usize,
}

pub fn default_synthetic_bench_db_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("generated")
        .join("benchmarks")
        .join("synthetic_clipboard.sqlite")
}

pub fn ensure_synthetic_benchmark_fixture(
    db_path: &Path,
    force_rebuild: bool,
) -> Result<SyntheticBenchSummary> {
    if db_path.exists() && !force_rebuild {
        return Ok(SyntheticBenchSummary {
            total_items: TOTAL_TEXT_ITEMS + TOTAL_LINK_ITEMS + TOTAL_IMAGE_ITEMS + TOTAL_FILE_ITEMS,
            total_text_bytes: expected_total_text_bytes(),
        });
    }

    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent)?;
    }

    remove_sqlite_sidecars(db_path)?;
    if db_path.exists() {
        fs::remove_file(db_path)?;
    }

    let db = Database::open(db_path)?;
    let mut rng = StdRng::seed_from_u64(FIXTURE_SEED);
    let mut total_text_bytes = 0usize;
    let base_timestamp = chrono::Utc::now().timestamp();

    for (ordinal, spec) in fixture_specs().into_iter().enumerate() {
        let (app_name, bundle_id) = SOURCE_APPS[rng.gen_range(0..SOURCE_APPS.len())];
        let mut item = build_item(spec, ordinal, &mut rng, app_name, bundle_id);
        if let FixtureSpec::Text { .. } = spec {
            total_text_bytes += item.text_content().len();
        }
        item.timestamp_unix = base_timestamp - ordinal as i64 * 90;
        db.insert_item(&item)?;
    }

    drop(db);

    let index_path = db_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!("tantivy_index_{}", crate::indexer::INDEX_VERSION));
    if index_path.exists() {
        fs::remove_dir_all(&index_path)?;
    }

    let indexer = Indexer::new(&index_path)?;
    let items = Database::open(db_path)?.fetch_all_items()?;
    indexer.clear()?;
    for item in items {
        if let Some(id) = item.id {
            let index_text = item
                .file_index_text()
                .unwrap_or_else(|| item.text_content().to_string());
            indexer.add_document(id, &index_text, item.timestamp_unix)?;
        }
    }
    indexer.commit()?;

    Ok(SyntheticBenchSummary {
        total_items: TOTAL_TEXT_ITEMS + TOTAL_LINK_ITEMS + TOTAL_IMAGE_ITEMS + TOTAL_FILE_ITEMS,
        total_text_bytes,
    })
}

fn remove_sqlite_sidecars(db_path: &Path) -> Result<()> {
    let shm = PathBuf::from(format!("{}-shm", db_path.display()));
    let wal = PathBuf::from(format!("{}-wal", db_path.display()));
    if shm.exists() {
        fs::remove_file(shm)?;
    }
    if wal.exists() {
        fs::remove_file(wal)?;
    }
    Ok(())
}

fn fixture_specs() -> Vec<FixtureSpec> {
    let mut specs = Vec::with_capacity(
        TOTAL_TEXT_ITEMS + TOTAL_LINK_ITEMS + TOTAL_IMAGE_ITEMS + TOTAL_FILE_ITEMS,
    );

    specs.extend(repeat_specs(
        TextSizeClass::Tiny,
        &spread_sizes(TINY_TEXT_ITEMS, 96, 920),
    ));
    specs.extend(repeat_specs(
        TextSizeClass::Small,
        &spread_sizes(SMALL_TEXT_ITEMS, 1_200, 9_600),
    ));
    specs.extend(repeat_specs(
        TextSizeClass::Medium,
        &spread_sizes(MEDIUM_TEXT_ITEMS, 12_000, 92_000),
    ));
    specs.extend(repeat_specs(TextSizeClass::Large, &LARGE_TEXT_TARGET_SIZES));
    specs.extend(repeat_specs(TextSizeClass::Huge, &HUGE_TEXT_TARGET_SIZES));

    specs.extend((0..TOTAL_LINK_ITEMS).map(|_| FixtureSpec::Link { target_size: 96 }));
    specs.extend((0..TOTAL_IMAGE_ITEMS).map(|_| FixtureSpec::Image { target_size: 256 }));
    specs.push(FixtureSpec::File { target_size: 256 });

    specs
}

fn repeat_specs(
    size_class: TextSizeClass,
    sizes: &[usize],
) -> impl Iterator<Item = FixtureSpec> + '_ {
    sizes
        .iter()
        .copied()
        .map(move |target_size| FixtureSpec::Text {
            size_class,
            target_size,
        })
}

fn spread_sizes(count: usize, min: usize, max: usize) -> Vec<usize> {
    if count == 0 {
        return Vec::new();
    }
    if count == 1 {
        return vec![max];
    }
    let span = max - min;
    (0..count)
        .map(|index| min + (span * index) / (count - 1))
        .collect()
}

fn build_item(
    spec: FixtureSpec,
    ordinal: usize,
    rng: &mut StdRng,
    app_name: &str,
    bundle_id: &str,
) -> StoredItem {
    match spec {
        FixtureSpec::Text {
            size_class,
            target_size,
        } => StoredItem::new_text(
            build_text_document(size_class, target_size, ordinal, rng),
            Some(app_name.to_string()),
            Some(bundle_id.to_string()),
        ),
        FixtureSpec::Link { .. } => StoredItem::new_text(
            format!(
                "https://{}/team-{}/search/{}?query={}",
                URL_HOSTS[rng.gen_range(0..URL_HOSTS.len())],
                ordinal % 17,
                ordinal,
                NOTE_SNIPPETS[ordinal % NOTE_SNIPPETS.len()]
                    .split_whitespace()
                    .take(3)
                    .collect::<Vec<_>>()
                    .join("-")
                    .to_lowercase()
            ),
            Some(app_name.to_string()),
            Some(bundle_id.to_string()),
        ),
        FixtureSpec::Image { target_size } => {
            let mut data = vec![0u8; target_size.max(128)];
            rng.fill(data.as_mut_slice());
            let mut thumbnail = vec![0u8; 96];
            rng.fill(thumbnail.as_mut_slice());
            StoredItem::new_image_with_thumbnail(
                data,
                Some(thumbnail),
                Some(app_name.to_string()),
                Some(bundle_id.to_string()),
                false,
            )
        }
        FixtureSpec::File { .. } => {
            let (ext, uti) = FILE_EXTENSIONS[rng.gen_range(0..FILE_EXTENSIONS.len())];
            StoredItem::new_file(
                format!("/Users/julsh/Projects/clipkitty/benchmark_fixture_{ordinal}.{ext}"),
                format!("benchmark_fixture_{ordinal}.{ext}"),
                32_768,
                uti.to_string(),
                vec![1, 2, 3, 4],
                None,
                Some(app_name.to_string()),
                Some(bundle_id.to_string()),
            )
        }
    }
}

fn build_text_document(
    size_class: TextSizeClass,
    target_size: usize,
    ordinal: usize,
    rng: &mut StdRng,
) -> String {
    let mut sections = Vec::new();
    match size_class {
        TextSizeClass::Tiny => {
            sections.push(format!(
                "note {}: {}",
                ordinal,
                NOTE_SNIPPETS[ordinal % NOTE_SNIPPETS.len()]
            ));
            if ordinal % 7 == 0 {
                sections.push("function error return class".to_string());
            }
        }
        TextSizeClass::Small | TextSizeClass::Medium => {
            sections.push(CODE_SNIPPETS[ordinal % CODE_SNIPPETS.len()].to_string());
            sections.push(format!(
                "Context: {}",
                NOTE_SNIPPETS[ordinal % NOTE_SNIPPETS.len()]
            ));
        }
        TextSizeClass::Large | TextSizeClass::Huge => {
            sections.push(format!(
                "Large benchmark document {}.\nThis item is intentionally dense with search terms like function, error, class, return, import, async, and lorem ipsum.\n\n",
                ordinal
            ));
            sections.push(CODE_SNIPPETS[ordinal % CODE_SNIPPETS.len()].repeat(8));
        }
    }

    let paragraph_target = match size_class {
        TextSizeClass::Tiny => 24,
        TextSizeClass::Small => 72,
        TextSizeClass::Medium => 180,
        TextSizeClass::Large => 600,
        TextSizeClass::Huge => 1_200,
    };

    while sections.iter().map(|part| part.len()).sum::<usize>() < target_size {
        sections.push(make_paragraph(paragraph_target, ordinal, rng));
        if matches!(size_class, TextSizeClass::Large | TextSizeClass::Huge) {
            sections.push(CODE_SNIPPETS[rng.gen_range(0..CODE_SNIPPETS.len())].to_string());
        }
    }

    let mut text = sections.join("\n\n");
    while text.len() > target_size && !text.is_char_boundary(target_size) {
        text.pop();
    }
    text.truncate(target_size.min(text.len()));
    text
}

fn make_paragraph(word_count: usize, ordinal: usize, rng: &mut StdRng) -> String {
    let mut words = Vec::with_capacity(word_count + 8);
    for index in 0..word_count {
        let token = match (ordinal + index) % 11 {
            0 => "function",
            1 => "error",
            2 => "class",
            3 => "return",
            4 => "lorem",
            5 => "ipsum",
            6 => "async",
            7 => "import",
            _ => NOTE_SNIPPETS[rng.gen_range(0..NOTE_SNIPPETS.len())]
                .split_whitespace()
                .nth((ordinal + index) % 5)
                .unwrap_or("search"),
        };
        words.push(token);
    }
    let mut paragraph = words.join(" ");
    if let Some(first) = paragraph.get_mut(0..1) {
        first.make_ascii_uppercase();
    }
    paragraph.push('.');
    paragraph
}

fn expected_total_text_bytes() -> usize {
    fixture_specs()
        .into_iter()
        .filter_map(|spec| match spec {
            FixtureSpec::Text { target_size, .. } => Some(target_size),
            FixtureSpec::Link { .. } | FixtureSpec::Image { .. } | FixtureSpec::File { .. } => None,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_fixture_matches_expected_counts() {
        let specs = fixture_specs();
        assert_eq!(
            specs.len(),
            TOTAL_TEXT_ITEMS + TOTAL_LINK_ITEMS + TOTAL_IMAGE_ITEMS + TOTAL_FILE_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(spec, FixtureSpec::Text { .. }))
                .count(),
            TOTAL_TEXT_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(spec, FixtureSpec::Link { .. }))
                .count(),
            TOTAL_LINK_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(spec, FixtureSpec::Image { .. }))
                .count(),
            TOTAL_IMAGE_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(spec, FixtureSpec::File { .. }))
                .count(),
            TOTAL_FILE_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(
                    spec,
                    FixtureSpec::Text {
                        size_class: TextSizeClass::Tiny,
                        ..
                    }
                ))
                .count(),
            TINY_TEXT_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(
                    spec,
                    FixtureSpec::Text {
                        size_class: TextSizeClass::Small,
                        ..
                    }
                ))
                .count(),
            SMALL_TEXT_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(
                    spec,
                    FixtureSpec::Text {
                        size_class: TextSizeClass::Medium,
                        ..
                    }
                ))
                .count(),
            MEDIUM_TEXT_ITEMS
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(
                    spec,
                    FixtureSpec::Text {
                        size_class: TextSizeClass::Large,
                        ..
                    }
                ))
                .count(),
            LARGE_TEXT_TARGET_SIZES.len()
        );
        assert_eq!(
            specs
                .iter()
                .filter(|spec| matches!(
                    spec,
                    FixtureSpec::Text {
                        size_class: TextSizeClass::Huge,
                        ..
                    }
                ))
                .count(),
            HUGE_TEXT_TARGET_SIZES.len()
        );
    }

    #[test]
    fn synthetic_fixture_total_text_is_large_enough_for_perf_testing() {
        let total_text_bytes = expected_total_text_bytes();
        assert!(total_text_bytes > 70 * 1024 * 1024);
        assert!(total_text_bytes < 80 * 1024 * 1024);
    }
}
