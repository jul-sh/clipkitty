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
    // --- Scene 2: Color/Image items ---
    DemoItem {
        content: "Orange tabby cat sleeping on mechanical keyboard",
        source_app: "Photos",
        bundle_id: "com.apple.Photos",
        offset: -1400,
    },
    DemoItem {
        content: "Architecture diagram with service mesh",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -1300,
    },
    DemoItem {
        content: "#7C3AED",
        source_app: "Freeform",
        bundle_id: "com.apple.freeform",
        offset: -1800,
    },
    DemoItem {
        content: "#FF5733",
        source_app: "Freeform",
        bundle_id: "com.apple.freeform",
        offset: -1700,
    },
    DemoItem {
        content: "#2DD4BF",
        source_app: "Preview",
        bundle_id: "com.apple.Preview",
        offset: -1600,
    },
    DemoItem {
        content: "#1E293B",
        source_app: "Freeform",
        bundle_id: "com.apple.freeform",
        offset: -1550,
    },
    DemoItem {
        content: "#F472B6",
        source_app: "Preview",
        bundle_id: "com.apple.Preview",
        offset: -1500,
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
    // --- Scene 1: Hello-related items ---
    DemoItem {
        content: "Hello ClipKitty!\n\n• Unlimited History\n• Instant Search\n• Private\n\nYour clipboard, supercharged.",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -600,
    },
    DemoItem {
        content: "Hello and welcome to the onboarding flow for new team members. This document covers everything you need to know about getting started...",
        source_app: "Reminders",
        bundle_id: "com.apple.reminders",
        offset: -500,
    },
    DemoItem {
        content: "hello_world.py",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -400,
    },
    DemoItem {
        content: "sayHello(user: User) -> String { ... }",
        source_app: "Automator",
        bundle_id: "com.apple.Automator",
        offset: -300,
    },
    DemoItem {
        content: "Othello character analysis notes",
        source_app: "Pages",
        bundle_id: "com.apple.iWork.Pages",
        offset: -280,
    },
    DemoItem {
        content: "hello_config.json",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -260,
    },
    DemoItem {
        content: "client_hello_handshake()",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -240,
    },
    DemoItem {
        content: "clipboard_manager_notes.md",
        source_app: "Stickies",
        bundle_id: "com.apple.Stickies",
        offset: -220,
    },
    DemoItem {
        content: "cache_hello_responses()",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -200,
    },
    DemoItem {
        content: "check_health_status()",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -180,
    },
    DemoItem {
        content: "HashMap<String, Vec<Box<dyn Handler>>>",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -160,
    },
    // --- Default/empty state items (most recent) ---
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
        content: "SELECT users.name, orders.total FROM orders JOIN users ON users.id = orders.user_id WHERE orders.status = 'completed' AND orders.created_at > NOW() - INTERVAL '30 days' ORDER BY orders.total DESC LIMIT 100;",
        source_app: "Numbers",
        bundle_id: "com.apple.Numbers",
        offset: -10,
    },
];