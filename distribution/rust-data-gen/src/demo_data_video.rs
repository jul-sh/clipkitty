//! Video-specific demo data for the intro video recording.
//! These items are inserted into SyntheticData_video.sqlite to showcase
//! ClipKitty's capabilities in a scripted intro video.

use crate::demo_data::DemoItem;

pub const VIDEO_ITEMS: &[DemoItem] = &[
    // Scene 1: Welcome message — most recent item, shown on launch
    DemoItem {
        content: "Welcome to ClipKitty! \u{1F431}\n\nBest clipboard manager.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
    // Scene 2: Fuzzy search target — "Copy, find forver" matches this
    DemoItem {
        content: "Copy it once, find it forever.\n\nUnlimited clipboard history.",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    // Scene 3: Multi-line preview with balloon ASCII art
    DemoItem {
        content: "Multi-line preview, so you see\nbefore you paste.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    // Scene 3.5: Secure/private — bookmarked via Cmd+K
    DemoItem {
        content: "- Secure and private\n- Your data stays yours\n- Open Source",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },
];
