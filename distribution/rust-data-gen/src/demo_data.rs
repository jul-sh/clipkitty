//! Shared demo data for synthetic data generation and tests.

pub struct DemoItem {
    pub content: &'static str,
    pub source_app: &'static str,
    pub bundle_id: &'static str,
    /// Relative offset in seconds from "now" (negative means in the past)
    pub offset: i64,
}

pub const DEMO_ITEMS: &[DemoItem] = &[
    // --- Scene 3: Old items ---
    DemoItem {
        content: "Apartment walkthrough notes: 437 Riverside Dr #12, hardwood floors throughout, south-facing windows with park views, original crown molding, in-unit washer/dryer, $2850/mo, super lives on-site, contact Marcus Realty about lease terms and move-in date flexibility...",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60, // 180 days ago
    },
    DemoItem {
        content: "riverside_park_picnic_directions.txt",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -3600,
    },
    DemoItem {
        content: "driver_config.yaml",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -3550,
    },
    DemoItem {
        content: "river_animation_keyframes.css",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -3500,
    },
    DemoItem {
        content: "derive_key_from_password(salt: Data, iterations: Int) -> Data { ... }",
        source_app: "Automator",
        bundle_id: "com.apple.Automator",
        offset: -3400,
    },
    DemoItem {
        content: "private_key_backup.pem",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -3300,
    },
    DemoItem {
        content: "return fetchData().then(res => res.json()).catch(handleError)...",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -3200,
    },
    DemoItem {
        content: "README.md",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -3100,
    },
    DemoItem {
        content: "RFC 2616 HTTP/1.1 Specification full text...",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -3000,
    },
    DemoItem {
        content: r#"grep -rn "TODO\|FIXME" ./src"#,
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -2900,
    },
    DemoItem {
        content: "border-radius: 8px;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -2800,
    },
    // Deploy command for search demo (fuzzy match target)
    DemoItem {
        content: "# Deploy API server to production\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60, // ~90 days ago (middle of history)
    },
    DemoItem {
        content: "Architecture diagram with service mesh",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -1300,
    },
    DemoItem {
        content: "#border-container { margin: 0; padding: 16px; display: flex; flex-direction: column; ...",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -1200,
    },
    DemoItem {
        content: "catalog_api_response.json",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -1100,
    },
    DemoItem {
        content: "catch (error) { logger.error(error); Sentry.captureException(error); ...",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -1000,
    },
    DemoItem {
        content: "concatenate_strings(a, b)",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -900,
    },
    DemoItem {
        content: r#"categories: [{ id: 1, name: "Electronics", subcategories: [...] }]"#,
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -800,
    },
    DemoItem {
        content: "#FF5733",
        source_app: "Freeform",
        bundle_id: "com.apple.freeform",
        offset: -200,  // Orange - shows in first 10 items
    },
    DemoItem {
        content: "#2DD4BF",
        source_app: "Preview",
        bundle_id: "com.apple.Preview",
        offset: -350,  // Teal - shows in first 10 items
    },
    DemoItem {
        content: "The quick brown fox jumps over the lazy dog",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "https://developer.apple.com/documentation/swiftui",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -60,
    },
    DemoItem {
        content: "#!/bin/bash\nset -euo pipefail\necho \"Deploying to prod...\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -40,
    },
    DemoItem {
        content: "ClipKitty\n• Copy it once, find it forever\n• Smart search handles typos\n• Preview before pasting\n• ⌥Space to summon, keyboard-first\n• Secure, on-device data storage",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];
