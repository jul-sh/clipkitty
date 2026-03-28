//! Localized video demo data for the intro video recording.
//!
//! Each locale has its own VIDEO_ITEMS and scene search queries that replace
//! the English content. Scene targets are fully translated; distractor items
//! translate plain-text content but keep code/commands in English.

use crate::DemoItem;

/// Localized search queries for each video scene.
pub struct LocalizedVideoScenes {
    pub welcome_query: &'static str,
    pub find_forever_query: &'static str,
    pub multiline_query: &'static str,
    pub secure_private_query: &'static str,
    pub fast_query: &'static str,
}

/// Returns localized scene search queries for a given locale.
/// Returns None for "en" (use default English queries).
pub fn get_localized_video_scenes(locale: &str) -> Option<&'static LocalizedVideoScenes> {
    match locale {
        "es" => Some(&VIDEO_SCENES_ES),
        "zh-Hans" => Some(&VIDEO_SCENES_ZH_HANS),
        "zh-Hant" => Some(&VIDEO_SCENES_ZH_HANT),
        "ja" => Some(&VIDEO_SCENES_JA),
        "ko" => Some(&VIDEO_SCENES_KO),
        "fr" => Some(&VIDEO_SCENES_FR),
        "de" => Some(&VIDEO_SCENES_DE),
        "pt-BR" => Some(&VIDEO_SCENES_PT_BR),
        "ru" => Some(&VIDEO_SCENES_RU),
        _ => None,
    }
}

/// Returns localized video items for a given locale.
/// Returns None for "en" (use default English items).
pub fn get_localized_video_items(locale: &str) -> Option<&'static [DemoItem]> {
    match locale {
        "es" => Some(VIDEO_ITEMS_ES),
        "zh-Hans" => Some(VIDEO_ITEMS_ZH_HANS),
        "zh-Hant" => Some(VIDEO_ITEMS_ZH_HANT),
        "ja" => Some(VIDEO_ITEMS_JA),
        "ko" => Some(VIDEO_ITEMS_KO),
        "fr" => Some(VIDEO_ITEMS_FR),
        "de" => Some(VIDEO_ITEMS_DE),
        "pt-BR" => Some(VIDEO_ITEMS_PT_BR),
        "ru" => Some(VIDEO_ITEMS_RU),
        _ => None,
    }
}

// ============================================================================
// Spanish (es)
// ============================================================================

const VIDEO_SCENES_ES: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "bienvenido clipkitty",
    find_forever_query: "copia encuentra siempre",
    multiline_query: "vista previa multilínea",
    secure_private_query: "seguro privado",
    fast_query: "rápido",
};

pub const VIDEO_ITEMS_ES: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "¡Bienvenido a ClipKitty! \u{1F431}\n\nEl mejor gestor de portapapeles.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "Cópialo una vez,\nencuéntralo siempre.\n\nHistorial ilimitado.",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "Vista previa multilínea,\nve antes de pegar.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- Seguro y privado\n- Tus datos son tuyos\n- Código abierto",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "bienvenido clipkitty" partials ──
    DemoItem {
        content: "Plantilla de correo de bienvenida: Hola {{name}}, ¡gracias por registrarte!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "¡Bienvenido al equipo! Aquí tienes tu lista de incorporación...",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"¡Bienvenido de nuevo!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Estimado visitante, bienvenido a nuestro portal de documentación",
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
        content: "¡Bienvenidos nuevos contribuidores! Por favor lean CONTRIBUTING.md antes de enviar PRs.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — pantalla inicial en el primer arranque",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "copia encuentra siempre" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # copiar artefactos de compilación a dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // copia superficial",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // copiar al portapapeles",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # copiar con progreso",
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
        content: "Érase una vez en una tierra lejana...",
        source_app: "Notas",
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

    // ── "vista previa multilínea" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # vista previa multi-rama",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # vista previa rápida",
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
        content: "Autenticación multifactor activada para todas las cuentas de administrador",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Proveedor de vista previa para ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cadena multilínea en Python:\n\"\"\"\nEsta es la línea uno\nEsta es la línea dos\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Despliegue de vista previa en https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # conteo de líneas del proyecto",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "vista previa de markdown: Cmd+Shift+V en VS Code",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "seguro privado" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN conectada: retransmisión privada activa, cifrado de 256 bits",
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
        content: "Aviso de seguridad: Actualizar para parchear CVE-2025-1234",
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
        content: "Autenticación biométrica: Face ID / Touch ID para desbloqueo seguro",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // nunca registrar esto",
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
        content: "Modo de navegación privada: sin historial, cookies eliminadas al cerrar",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "rápido" partials ──
    DemoItem {
        content: "Puntuación Lighthouse: Rendimiento 98, First Contentful Paint 0.8s",
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
        content: "desayuno reunión a las 9am — traer portátil",
        source_app: "Notas",
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
        content: "rendimiento estable: 12k req/s con p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # binario rápido optimizado",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — omitir rebase, fusionar directamente",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Benchmark: SQLite modo WAL 3x más rápido que modo journal",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: odometría lidar-inercial en tiempo real",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Simplified Chinese (zh-Hans)
// ============================================================================

const VIDEO_SCENES_ZH_HANS: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "欢迎 clipkitty",
    find_forever_query: "复制 永久查找",
    multiline_query: "多行预览",
    secure_private_query: "安全 隐私",
    fast_query: "飞快",
};

pub const VIDEO_ITEMS_ZH_HANS: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "欢迎使用 ClipKitty! \u{1F431}\n\n最好的剪贴板管理器。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "复制一次，永久查找。\n\n无限剪贴板历史记录。",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "多行预览，\n粘贴前先看清。\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- 安全且隐私\n- 数据始终属于你\n- 开源",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "欢迎 clipkitty" partials ──
    DemoItem {
        content: "欢迎邮件模板：你好 {{name}}，感谢注册！",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "欢迎加入团队！这是你的入职清单...",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"欢迎回来！\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "亲爱的访客，欢迎来到我们的文档门户",
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
        content: "欢迎新贡献者！提交 PR 前请阅读 CONTRIBUTING.md。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — 首次启动时显示的初始屏幕",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "复制 永久查找" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # 复制构建产物到 dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // 浅拷贝",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // 复制到剪贴板",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # 带进度复制",
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
        content: "很久很久以前，在一个遥远的地方...",
        source_app: "备忘录",
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

    // ── "多行预览" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # 多分支预览",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # 快速预览",
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
        content: "已为所有管理员账户启用多因素认证",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// ContentView 的预览提供器\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "Python 多行字符串：\n\"\"\"\n这是第一行\n这是第二行\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "预览部署地址 https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # 项目行数统计",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "markdown 预览：VS Code 中 Cmd+Shift+V",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "安全 隐私" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN 已连接：隐私中继已启用，256 位加密",
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
        content: "安全公告：更新以修补 CVE-2025-1234",
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
        content: "生物识别认证：Face ID / Touch ID 安全解锁",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // 切勿记录此值",
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
        content: "隐私浏览模式：无历史记录，关闭时清除 Cookie",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "飞快" partials ──
    DemoItem {
        content: "Lighthouse 评分：性能 98，首次内容绘制 0.8s",
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
        content: "早餐会议上午9点 — 带笔记本电脑",
        source_app: "备忘录",
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
        content: "稳态吞吐量：12k req/s，p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # 飞快优化二进制",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — 跳过变基，直接合并",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "基准测试：SQLite WAL 模式比日志模式快 3 倍",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: 实时激光雷达惯性里程计",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Traditional Chinese (zh-Hant)
// ============================================================================

const VIDEO_SCENES_ZH_HANT: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "歡迎 clipkitty",
    find_forever_query: "複製 永遠找到",
    multiline_query: "多行預覽",
    secure_private_query: "安全 隱私",
    fast_query: "飛快",
};

pub const VIDEO_ITEMS_ZH_HANT: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "歡迎使用 ClipKitty! \u{1F431}\n\n最好的剪貼簿管理器。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "複製一次，永遠找得到。\n\n無限剪貼簿歷史記錄。",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "多行預覽，\n貼上前先看清。\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- 安全且隱私\n- 資料始終屬於你\n- 開源",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "歡迎 clipkitty" partials ──
    DemoItem {
        content: "歡迎郵件範本：你好 {{name}}，感謝註冊！",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "歡迎加入團隊！這是你的入職清單...",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"歡迎回來！\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "親愛的訪客，歡迎來到我們的文件入口",
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
        content: "歡迎新貢獻者！提交 PR 前請閱讀 CONTRIBUTING.md。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — 首次啟動時顯示的初始畫面",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "複製 永遠找到" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # 複製建構產物到 dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // 淺拷貝",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // 複製到剪貼簿",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # 帶進度複製",
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
        content: "很久很久以前，在一個遙遠的地方...",
        source_app: "備忘錄",
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

    // ── "多行預覽" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # 多分支預覽",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # 快速預覽",
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
        content: "已為所有管理員帳戶啟用多重要素驗證",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// ContentView 的預覽提供器\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "Python 多行字串：\n\"\"\"\n這是第一行\n這是第二行\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "預覽部署位址 https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # 專案行數統計",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "markdown 預覽：VS Code 中 Cmd+Shift+V",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "安全 隱私" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN 已連線：隱私中繼已啟用，256 位元加密",
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
        content: "安全公告：更新以修補 CVE-2025-1234",
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
        content: "生物辨識驗證：Face ID / Touch ID 安全解鎖",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // 切勿記錄此值",
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
        content: "隱私瀏覽模式：無歷史記錄，關閉時清除 Cookie",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "飛快" partials ──
    DemoItem {
        content: "Lighthouse 評分：效能 98，首次內容繪製 0.8s",
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
        content: "早餐會議上午9點 — 帶筆電",
        source_app: "備忘錄",
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
        content: "穩態吞吐量：12k req/s，p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # 飛快最佳化二進位",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — 跳過變基，直接合併",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "基準測試：SQLite WAL 模式比日誌模式快 3 倍",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: 即時光達慣性里程計",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Japanese (ja)
// ============================================================================

const VIDEO_SCENES_JA: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "ようこそ clipkitty",
    find_forever_query: "コピー いつでも見つかる",
    multiline_query: "複数行プレビュー",
    secure_private_query: "安全 プライベート",
    fast_query: "爆速",
};

pub const VIDEO_ITEMS_JA: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "ClipKitty へようこそ! \u{1F431}\n\n最高のクリップボード管理。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "一度コピーすれば、\nいつでも見つかる。\n\n無制限のクリップボード履歴。",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "複数行プレビューで、\n貼り付け前に確認。\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- 安全でプライベート\n- データはあなたのもの\n- オープンソース",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "ようこそ clipkitty" partials ──
    DemoItem {
        content: "ようこそメールテンプレート：{{name}} 様、ご登録ありがとうございます！",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "チームへようこそ！オンボーディングチェックリストはこちら...",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"おかえりなさい！\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "ご訪問者様、ドキュメントポータルへようこそ",
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
        content: "新しいコントリビューターの皆さん、ようこそ！PR 提出前に CONTRIBUTING.md をお読みください。",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — 初回起動時の初期画面",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "コピー いつでも見つかる" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # ビルド成果物を dist にコピー",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // 浅いコピー",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // クリップボードにコピー",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # 進捗付きコピー",
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
        content: "むかしむかし、遠い国で...",
        source_app: "メモ",
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

    // ── "複数行プレビュー" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # 複数ブランチプレビュー",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # クイックルックプレビュー",
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
        content: "全管理者アカウントで多要素認証が有効",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// ContentView のプレビュープロバイダー\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "Python の複数行文字列：\n\"\"\"\nこれは1行目\nこれは2行目\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "プレビューデプロイ先 https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # プロジェクトの行数",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "markdown プレビュー：VS Code で Cmd+Shift+V",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "安全 プライベート" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN 接続済み：プライベートリレー有効、256 ビット暗号化",
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
        content: "セキュリティ勧告：CVE-2025-1234 のパッチを適用してください",
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
        content: "生体認証：Face ID / Touch ID で安全にロック解除",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // ログに出力しないこと",
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
        content: "プライベートブラウズモード：履歴なし、終了時に Cookie を消去",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "爆速" partials ──
    DemoItem {
        content: "Lighthouse スコア：パフォーマンス 98、FCP 0.8s",
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
        content: "朝食ミーティング午前9時 — ノートPC持参",
        source_app: "メモ",
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
        content: "定常スループット：12k req/s、p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # 爆速最適化バイナリ",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — リベースをスキップ、直接マージ",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "ベンチマーク：SQLite WAL モードはジャーナルモードの 3 倍高速",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: リアルタイム LiDAR 慣性オドメトリ",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Korean (ko)
// ============================================================================

const VIDEO_SCENES_KO: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "환영 clipkitty",
    find_forever_query: "복사 영원히 검색",
    multiline_query: "여러 줄 미리보기",
    secure_private_query: "안전 비공개",
    fast_query: "빠름",
};

pub const VIDEO_ITEMS_KO: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "ClipKitty에 오신 것을 환영합니다! \u{1F431}\n\n최고의 클립보드 관리자.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "한 번 복사하면,\n영원히 검색 가능.\n\n무제한 클립보드 기록.",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "여러 줄 미리보기로,\n붙여넣기 전에 확인.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- 안전하고 비공개\n- 데이터는 당신의 것\n- 오픈 소스",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "환영 clipkitty" partials ──
    DemoItem {
        content: "환영 이메일 템플릿: 안녕하세요 {{name}}님, 가입해 주셔서 감사합니다!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "팀에 오신 것을 환영합니다! 온보딩 체크리스트입니다...",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"다시 오신 것을 환영합니다!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "방문자님, 문서 포털에 오신 것을 환영합니다",
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
        content: "새 기여자 여러분 환영합니다! PR 제출 전에 CONTRIBUTING.md를 읽어주세요.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — 첫 실행 시 표시되는 초기 화면",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "복사 영원히 검색" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # 빌드 산출물을 dist로 복사",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // 얕은 복사",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // 클립보드에 복사",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # 진행률 표시 복사",
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
        content: "옛날 옛적에 먼 나라에서...",
        source_app: "메모",
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

    // ── "여러 줄 미리보기" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # 다중 브랜치 미리보기",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # 빠른 미리보기",
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
        content: "모든 관리자 계정에 다중 인증 활성화됨",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// ContentView 미리보기 프로바이더\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "Python 여러 줄 문자열:\n\"\"\"\n첫 번째 줄\n두 번째 줄\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "미리보기 배포: https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # 프로젝트 줄 수 세기",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "markdown 미리보기: VS Code에서 Cmd+Shift+V",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "안전 비공개" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN 연결됨: 비공개 릴레이 활성, 256비트 암호화",
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
        content: "보안 권고: CVE-2025-1234 패치 업데이트",
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
        content: "생체 인증: Face ID / Touch ID로 안전한 잠금 해제",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // 절대 로그에 기록하지 말 것",
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
        content: "비공개 브라우징 모드: 기록 없음, 종료 시 쿠키 삭제",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "빠름" partials ──
    DemoItem {
        content: "Lighthouse 점수: 성능 98, First Contentful Paint 0.8s",
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
        content: "아침 회의 오전 9시 — 노트북 지참",
        source_app: "메모",
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
        content: "정상 처리량: 12k req/s, p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # 빠른 최적화 바이너리",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — 리베이스 건너뛰기, 직접 병합",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "벤치마크: SQLite WAL 모드가 저널 모드보다 3배 빠름",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: 실시간 라이다 관성 주행거리 측정",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// French (fr)
// ============================================================================

const VIDEO_SCENES_FR: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "bienvenue clipkitty",
    find_forever_query: "copiez retrouvez toujours",
    multiline_query: "aperçu multiligne",
    secure_private_query: "sécurisé privé",
    fast_query: "rapide",
};

pub const VIDEO_ITEMS_FR: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "Bienvenue sur ClipKitty ! \u{1F431}\n\nLe meilleur gestionnaire\nde presse-papiers.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "Copiez une fois,\nretrouvez toujours.\n\nHistorique illimité.",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "Aperçu multiligne,\nvoyez avant de coller.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- Sécurisé et privé\n- Vos données restent vôtres\n- Open Source",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "bienvenue clipkitty" partials ──
    DemoItem {
        content: "Modèle d'e-mail de bienvenue : Bonjour {{name}}, merci pour votre inscription !",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "Bienvenue dans l'équipe ! Voici votre liste d'intégration...",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"Bon retour !\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Cher visiteur, bienvenue sur notre portail de documentation",
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
        content: "Bienvenue aux nouveaux contributeurs ! Veuillez lire CONTRIBUTING.md avant de soumettre des PR.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — écran initial au premier lancement",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "copiez retrouvez toujours" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # copier les artefacts de build vers dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // copie superficielle",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // copier dans le presse-papiers",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # copier avec progression",
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
        content: "Il était une fois dans un pays lointain...",
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

    // ── "aperçu multiligne" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # aperçu multi-branches",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # aperçu rapide",
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
        content: "Authentification multifacteur activée pour tous les comptes administrateur",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Fournisseur d'aperçu pour ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "chaîne multiligne en Python :\n\"\"\"\nCeci est la ligne un\nCeci est la ligne deux\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Déploiement d'aperçu : https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # nombre de lignes du projet",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "aperçu markdown : Cmd+Shift+V dans VS Code",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "sécurisé privé" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN connecté : relais privé actif, chiffrement 256 bits",
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
        content: "Avis de sécurité : Mettre à jour pour corriger CVE-2025-1234",
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
        content: "Authentification biométrique : Face ID / Touch ID pour déverrouillage sécurisé",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // ne jamais journaliser ceci",
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
        content: "Navigation privée : pas d'historique, cookies effacés à la fermeture",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "rapide" partials ──
    DemoItem {
        content: "Score Lighthouse : Performance 98, First Contentful Paint 0.8s",
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
        content: "petit-déjeuner réunion à 9h — apporter le portable",
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
        content: "débit stable : 12k req/s avec p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # binaire rapide optimisé",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — pas de rebase, fusion directe",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Benchmark : SQLite mode WAL 3x plus rapide que le mode journal",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2 : odométrie lidar-inertielle en temps réel",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// German (de)
// ============================================================================

const VIDEO_SCENES_DE: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "willkommen clipkitty",
    find_forever_query: "kopieren finden immer",
    multiline_query: "mehrzeilige Vorschau",
    secure_private_query: "sicher privat",
    fast_query: "schnell",
};

pub const VIDEO_ITEMS_DE: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "Willkommen bei ClipKitty! \u{1F431}\n\nDer beste Zwischenablage-Manager.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "Einmal kopieren,\nimmer finden.\n\nUnbegrenzter Verlauf.",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "Mehrzeilige Vorschau,\nsieh vor dem Einfügen.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- Sicher und privat\n- Deine Daten gehören dir\n- Open Source",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "willkommen clipkitty" partials ──
    DemoItem {
        content: "Willkommens-E-Mail-Vorlage: Hallo {{name}}, danke für deine Anmeldung!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "Willkommen im Team! Hier ist deine Onboarding-Checkliste...",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"Willkommen zurück!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Lieber Besucher, willkommen auf unserem Dokumentationsportal",
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
        content: "Willkommen neue Mitwirkende! Bitte lest CONTRIBUTING.md bevor ihr PRs einreicht.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — Startbildschirm beim ersten Start",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "kopieren finden immer" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # Build-Artefakte nach dist kopieren",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // flache Kopie",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // in Zwischenablage kopieren",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # mit Fortschritt kopieren",
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
        content: "Es war einmal in einem fernen Land...",
        source_app: "Notizen",
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

    // ── "mehrzeilige Vorschau" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # Mehrzweig-Vorschau",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # Schnellvorschau",
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
        content: "Multi-Faktor-Authentifizierung für alle Admin-Konten aktiviert",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Vorschau-Provider für ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "mehrzeiliger String in Python:\n\"\"\"\nDas ist Zeile eins\nDas ist Zeile zwei\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Vorschau-Deployment unter https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # Zeilenanzahl im Projekt",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "Markdown-Vorschau: Cmd+Shift+V in VS Code",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "sicher privat" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN verbunden: privates Relay aktiv, 256-Bit-Verschlüsselung",
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
        content: "Sicherheitshinweis: Update zum Patchen von CVE-2025-1234",
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
        content: "Biometrische Authentifizierung: Face ID / Touch ID für sicheres Entsperren",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // niemals loggen",
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
        content: "Privates Surfen: kein Verlauf, Cookies beim Schließen gelöscht",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "schnell" partials ──
    DemoItem {
        content: "Lighthouse-Score: Leistung 98, First Contentful Paint 0.8s",
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
        content: "Frühstücksmeeting um 9 Uhr — Laptop mitbringen",
        source_app: "Notizen",
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
        content: "stabiler Durchsatz: 12k req/s mit p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # schnelles optimiertes Binary",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — Rebase überspringen, direkt mergen",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Benchmark: SQLite WAL-Modus 3x schneller als Journal-Modus",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: Echtzeit-Lidar-Inertial-Odometrie",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Brazilian Portuguese (pt-BR)
// ============================================================================

const VIDEO_SCENES_PT_BR: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "bem-vindo clipkitty",
    find_forever_query: "copie encontre sempre",
    multiline_query: "pré-visualização multilinha",
    secure_private_query: "seguro privado",
    fast_query: "rápido",
};

pub const VIDEO_ITEMS_PT_BR: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "Bem-vindo ao ClipKitty! \u{1F431}\n\nO melhor gerenciador\nde área de transferência.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "Copie uma vez,\nencontre para sempre.\n\nHistórico ilimitado.",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "Pré-visualização multilinha,\nveja antes de colar.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- Seguro e privado\n- Seus dados são seus\n- Código aberto",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "bem-vindo clipkitty" partials ──
    DemoItem {
        content: "Modelo de e-mail de boas-vindas: Olá {{name}}, obrigado por se cadastrar!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "Bem-vindo à equipe! Aqui está sua lista de integração...",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"Bem-vindo de volta!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Caro visitante, bem-vindo ao nosso portal de documentação",
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
        content: "Bem-vindos novos contribuidores! Leiam CONTRIBUTING.md antes de enviar PRs.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — tela inicial na primeira execução",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "copie encontre sempre" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # copiar artefatos de build para dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // cópia rasa",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // copiar para área de transferência",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # copiar com progresso",
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
        content: "Era uma vez em uma terra distante...",
        source_app: "Notas",
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

    // ── "pré-visualização multilinha" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # pré-visualização multi-branch",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # pré-visualização rápida",
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
        content: "Autenticação multifator ativada para todas as contas de administrador",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Provedor de pré-visualização para ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "string multilinha em Python:\n\"\"\"\nEsta é a linha um\nEsta é a linha dois\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Deploy de pré-visualização em https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # contagem de linhas do projeto",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "pré-visualização markdown: Cmd+Shift+V no VS Code",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "seguro privado" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN conectada: relay privado ativo, criptografia de 256 bits",
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
        content: "Aviso de segurança: Atualize para corrigir CVE-2025-1234",
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
        content: "Autenticação biométrica: Face ID / Touch ID para desbloqueio seguro",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // nunca registrar isso",
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
        content: "Navegação privada: sem histórico, cookies apagados ao fechar",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "rápido" partials ──
    DemoItem {
        content: "Pontuação Lighthouse: Desempenho 98, First Contentful Paint 0.8s",
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
        content: "reunião de café da manhã às 9h — trazer notebook",
        source_app: "Notas",
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
        content: "throughput estável: 12k req/s com p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # binário rápido otimizado",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — pular rebase, merge direto",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Benchmark: SQLite modo WAL 3x mais rápido que modo journal",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: odometria lidar-inercial em tempo real",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];

// ============================================================================
// Russian (ru)
// ============================================================================

const VIDEO_SCENES_RU: LocalizedVideoScenes = LocalizedVideoScenes {
    welcome_query: "добро пожаловать clipkitty",
    find_forever_query: "скопируй найди всегда",
    multiline_query: "многострочный предпросмотр",
    secure_private_query: "безопасно приватно",
    fast_query: "быстро",
};

pub const VIDEO_ITEMS_RU: &[DemoItem] = &[
    // Scene targets
    DemoItem {
        content: "Добро пожаловать\nв ClipKitty! \u{1F431}\n\nЛучший менеджер буфера обмена.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -200,
    },
    DemoItem {
        content: "Скопируй один раз —\nнайди всегда.\n\nБезлимитная история.",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "Многострочный предпросмотр,\nсмотри перед вставкой.\n\n\u{2063}          \u{1F388}\u{1F388}  \u{2601}\u{FE0F}\n         \u{1F388}\u{1F388}\u{1F388}\n \u{2601}\u{FE0F}     \u{1F388}\u{1F388}\u{1F388}\u{1F388}\n   \u{2601}\u{FE0F}    \u{2063}\u{1F388}\u{1F388}\u{1F388}\n           \\|/\n           \u{1F3E0}   \u{2601}\u{FE0F}\n   \u{2601}\u{FE0F}         \u{2601}\u{FE0F}",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -300,
    },
    DemoItem {
        content: "- Безопасно и приватно\n- Ваши данные — только ваши\n- Открытый исходный код",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -500,
    },

    // ── "добро пожаловать clipkitty" partials ──
    DemoItem {
        content: "Шаблон приветственного письма: Здравствуйте, {{name}}, спасибо за регистрацию!",
        source_app: "Mail",
        bundle_id: "com.apple.mail",
        offset: -14 * 86400,
    },
    DemoItem {
        content: "onboarding_welcome_screen.swift",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -21 * 86400,
    },
    DemoItem {
        content: "Добро пожаловать в команду! Вот ваш чек-лист по адаптации...",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "new_user_welcome_banner.png",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -30 * 86400,
    },
    DemoItem {
        content: "func showWelcomeAlert(user: User) {\n    let alert = NSAlert()\n    alert.messageText = \"С возвращением!\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "Уважаемый посетитель, добро пожаловать на наш портал документации",
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
        content: "Добро пожаловать, новые участники! Прочтите CONTRIBUTING.md перед отправкой PR.",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "WelcomeView.swift — начальный экран при первом запуске",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -22 * 86400,
    },

    // ── "скопируй найди всегда" partials ──
    DemoItem {
        content: "cp -r ./build ./dist  # скопировать артефакты сборки в dist",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -7 * 86400,
    },
    DemoItem {
        content: "Object.assign({}, original)  // поверхностная копия",
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
        content: "NSPasteboard.general.setString(text, forType: .string)  // скопировать в буфер обмена",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -8 * 86400,
    },
    DemoItem {
        content: "rsync -avz --progress src/ backup/  # копирование с прогрессом",
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
        content: "Давным-давно в далёкой стране...",
        source_app: "Заметки",
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

    // ── "многострочный предпросмотр" partials ──
    DemoItem {
        content: "lineHeight: 1.5;\nfont-size: 14px;\ntext-rendering: optimizeLegibility;",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "git log --oneline --graph  # предпросмотр нескольких веток",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -12 * 86400,
    },
    DemoItem {
        content: "qlmanage -p report.pdf  # быстрый предпросмотр",
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
        content: "Многофакторная аутентификация включена для всех учётных записей администраторов",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10 * 86400,
    },
    DemoItem {
        content: "// Провайдер предпросмотра для ContentView\nstruct ContentView_Previews: PreviewProvider {\n    static var previews: some View {\n        ContentView()\n    }\n}",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "многострочная строка в Python:\n\"\"\"\nЭто первая строка\nЭто вторая строка\n\"\"\"",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Предпросмотр деплоя: https://staging.example.com/pr-42",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
    DemoItem {
        content: "wc -l src/**/*.swift  # подсчёт строк в проекте",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -26 * 86400,
    },
    DemoItem {
        content: "предпросмотр markdown: Cmd+Shift+V в VS Code",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -28 * 86400,
    },

    // ── "безопасно приватно" partials ──
    DemoItem {
        content: "ssh-keygen -t ed25519 -C \"secure-deploy-key\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -5 * 86400,
    },
    DemoItem {
        content: "VPN подключён: приватный ретранслятор активен, 256-битное шифрование",
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
        content: "Уведомление безопасности: Обновите для исправления CVE-2025-1234",
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
        content: "Биометрическая аутентификация: Face ID / Touch ID для безопасной разблокировки",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -17 * 86400,
    },
    DemoItem {
        content: "private var accessToken: String?  // никогда не логировать",
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
        content: "Приватный просмотр: без истории, cookies удаляются при закрытии",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -23 * 86400,
    },

    // ── "быстро" partials ──
    DemoItem {
        content: "Оценка Lighthouse: Производительность 98, FCP 0.8s",
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
        content: "встреча за завтраком в 9 утра — взять ноутбук",
        source_app: "Заметки",
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
        content: "стабильная пропускная способность: 12k req/s, p99 < 5ms",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -16 * 86400,
    },
    DemoItem {
        content: "cargo build --release  # быстрый оптимизированный бинарник",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -18 * 86400,
    },
    DemoItem {
        content: "fast_forward_merge.sh — пропустить rebase, мержить напрямую",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -20 * 86400,
    },
    DemoItem {
        content: "Бенчмарк: SQLite WAL-режим в 3 раза быстрее журнального",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -22 * 86400,
    },
    DemoItem {
        content: "FAST-LIO2: лидарно-инерциальная одометрия в реальном времени",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -24 * 86400,
    },
];
