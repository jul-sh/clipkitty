//! Video-specific demo data for the intro video recording.
//! These items are inserted into SyntheticData_video.sqlite to showcase
//! ClipKitty's capabilities in a scripted intro video.

use crate::DemoItem;

// ── Target items: the item each scene's search must find ─────────────

pub const SCENE_WELCOME: DemoItem = DemoItem {
    content: "Welcome to ClipKitty! \u{1F431}\n\nBest clipboard manager.",
    source_app: "Safari",
    bundle_id: "com.apple.Safari",
    offset: -200,
};

pub const SCENE_FIND_FOREVER: DemoItem = DemoItem {
    content: "Copy it once, find it forever.\n\nUnlimited clipboard history.",
    source_app: "Notes",
    bundle_id: "com.apple.Notes",
    // Smallest offset of any demo item so this sits at the top of history
    // when the intro video opens, giving us a recognizable first item before
    // any search.
    offset: -5,
};

pub const SCENE_MULTILINE: DemoItem = DemoItem {
    content: "Multi-line preview, so you see\nbefore you paste.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
    source_app: "Notes",
    bundle_id: "com.apple.Notes",
    offset: -300,
};

pub const SCENE_SECURE_PRIVATE: DemoItem = DemoItem {
    content: "- Secure and private\n- Your data stays yours\n- Open Source",
    source_app: "Safari",
    bundle_id: "com.apple.Safari",
    offset: -500,
};

/// A scene in the intro video: what to type and which item should rank first.
pub struct VideoScene {
    /// The search query typed during this scene
    pub query: &'static str,
    /// The target item that must rank first
    pub target: &'static DemoItem,
}

/// The intro video script: each scene's search query and expected top result.
/// Order matches the video flow. Used by both the UI test and ranking tests.
/// Note: the "fast" scene's target is an image item in the base DB, not here.
pub const VIDEO_SCENES: &[VideoScene] = &[
    VideoScene {
        query: "welcome clipkitty",
        target: &SCENE_WELCOME,
    },
    VideoScene {
        query: "copy once find forever",
        target: &SCENE_FIND_FOREVER,
    },
    VideoScene {
        query: "Multi-line preview",
        target: &SCENE_MULTILINE,
    },
    VideoScene {
        query: "secure private",
        target: &SCENE_SECURE_PRIVATE,
    },
];

pub const VIDEO_ITEMS: &[DemoItem] = &[
    // Scene targets (duplicated here for DB insertion; canonical values above)
    SCENE_WELCOME,
    SCENE_FIND_FOREVER,
    SCENE_MULTILINE,
    SCENE_SECURE_PRIVATE,
    // --- Extra items: partial keyword matches to fill search results ---

    // ── "welcome clipkitty" partials ──
    DemoItem {
        content: "Welcome email template: Hi {{name}}, thanks for signing up!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400, // 2 weeks ago
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400, // 3 weeks ago
    },
    DemoItem {
        content: "Welcome to the team! Here's your onboarding checklist...",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400, // 10 days ago
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400, // 1 month ago
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"Welcome back!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Dear visitor, welcome to our documentation portal",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -25 * 86400,
    },
    DemoItem {
        content: "kitty.conf: font_size 13.0, cursor_shape beam",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "brew install --cask kitty",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Welcome new contributors! Please read CONTRIBUTING.md before submitting PRs.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — initial screen shown on first launch",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "copy once find forever" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # copy build artifacts to dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // shallow copy",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -9 * 86400,
    },
    DemoItem {
        content: "find . -name '*.log' -mtime +30 -delete",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -11 * 86400,
    },
    DemoItem {
        content: "NSPasteboard.general.setString(text, forType: .string)  // copy to clipboard",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # copy with progress",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -13 * 86400,
    },
    DemoItem {
        content: "find /var/log -name '*.gz' -exec zcat {} \\; | grep ERROR",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -15 * 86400,
    },
    DemoItem {
        content: "let copy = structuredClone(deepObject)",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "Once upon a time in a land far away...",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -19 * 86400,
    },
    DemoItem {
        content: "SELECT * FROM bookmarks WHERE forever = true ORDER BY created_at",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -6 * 86400,
    },
    DemoItem {
        content: "docker cp container:/app/data ./local-copy",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -23 * 86400,
    },

    // ── "Multi-line preview" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # multi-branch preview",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # Quick Look preview",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "SwiftUI: .previewLayout(.sizeThatFits)",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "Multi-factor authentication enabled for all admin accounts",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Preview provider for ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "multi-line string in Python:\n\"\"\"\nThis is line one\nThis is line two\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Preview deployment at https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # line count across project",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "markdown preview: Cmd+Shift+V in VS Code",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "secure private" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN connected: private relay active, 256-bit encryption",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -9 * 86400,
    },
    DemoItem {
        content: "let store = SecureEnclave.loadKey(tag: \"com.app.signing\")",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -11 * 86400,
    },
    DemoItem {
        content: "openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -13 * 86400,
    },
    DemoItem {
        content: "Security Advisory: Update to patch CVE-2025-1234",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -15 * 86400,
    },
    DemoItem {
        content: "private func encryptPayload(_ data: Data) -> Data {\n    return AES.GCM.seal(data, using: key)",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Biometric authentication: Face ID / Touch ID for secure unlock",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // never log this",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -19 * 86400,
    },
    DemoItem {
        content: "Content-Security-Policy: default-src 'self'; script-src 'self'",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "Private browsing mode: no history, cookies cleared on close",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "fast" partials ──
    DemoItem {
        content: "Lighthouse score: Performance 98, First Contentful Paint 0.8s",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -6 * 86400,
    },
    DemoItem {
        content: "fastlane match --type appstore --readonly",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "breakfast meeting at 9am — bring laptop",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "npm run build -- --fast-refresh",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "FastAPI endpoint: @app.get(\"/health\")",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "steady-state throughput: 12k req/s with p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # fast optimized binary",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — skip rebase, merge directly",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Benchmark: SQLite WAL mode 3x faster than journal mode",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: real-time lidar-inertial odometry",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];
