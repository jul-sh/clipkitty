//! Localized demo data for marketing screenshots.
//!
//! Each locale has its own DEMO_ITEMS that replace the English content.
//! The fuzzy search demo uses locale-appropriate search terms.

use super::demo_data::DemoItem;
use once_cell::sync::Lazy;
use std::collections::HashMap;

/// Get localized demo items for a specific locale.
/// Returns None for "en" (use default English items).
pub fn get_localized_demo_items(locale: &str) -> Option<&'static [DemoItem]> {
    match locale {
        "es" => Some(DEMO_ITEMS_ES),
        "zh-Hans" => Some(DEMO_ITEMS_ZH_HANS),
        "zh-Hant" => Some(DEMO_ITEMS_ZH_HANT),
        "ja" => Some(DEMO_ITEMS_JA),
        "ko" => Some(DEMO_ITEMS_KO),
        "fr" => Some(DEMO_ITEMS_FR),
        "de" => Some(DEMO_ITEMS_DE),
        "pt-BR" => Some(DEMO_ITEMS_PT_BR),
        "ru" => Some(DEMO_ITEMS_RU),
        _ => None,
    }
}

// Lazy-loaded CSV data structure
// Maps (locale, filename) -> keywords
static IMAGE_KEYWORDS: Lazy<HashMap<(String, String), String>> = Lazy::new(|| {
    load_image_keywords().unwrap_or_else(|e| {
        eprintln!("Warning: Failed to load image keywords CSV: {}", e);
        HashMap::new()
    })
});

/// Load image keywords from CSV file
fn load_image_keywords() -> Result<HashMap<(String, String), String>, Box<dyn std::error::Error>> {
    let csv_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .ok_or("Failed to get parent directory")?
        .join("image_keywords.csv");

    let mut reader = csv::Reader::from_path(csv_path)?;
    let mut map = HashMap::new();

    // Get header to map locale names to column indices
    let headers = reader.headers()?.clone();
    let locale_indices: HashMap<&str, usize> = headers
        .iter()
        .enumerate()
        .skip(1) // Skip 'filename' column
        .map(|(idx, name)| (name, idx))
        .collect();

    for result in reader.records() {
        let record = result?;
        let filename = record.get(0).ok_or("Missing filename column")?.to_string();

        // Store keywords for each locale
        for (locale, &col_idx) in &locale_indices {
            if let Some(keywords) = record.get(col_idx) {
                if !keywords.is_empty() {
                    map.insert((locale.to_string(), filename.clone()), keywords.to_string());
                }
            }
        }
    }

    Ok(map)
}

/// Get localized image keywords for a specific image and locale.
/// Returns the localized keywords string for the given image filename.
/// The keywords are used as the image description in the database.
pub fn get_localized_image_keywords(locale: &str, filename: &str) -> Option<&'static str> {
    IMAGE_KEYWORDS
        .get(&(locale.to_string(), filename.to_string()))
        .map(|s| {
            // SAFETY: We're returning a reference to a string in a static HashMap
            // that lives for the entire program lifetime, so this is safe.
            let ptr = s.as_str() as *const str;
            unsafe { &*ptr }
        })
}

// ============================================================================
// Spanish (es)
// ============================================================================
pub const DEMO_ITEMS_ES: &[DemoItem] = &[
    // Old item (apartment notes equivalent)
    DemoItem {
        content: "Notas del recorrido del apartamento: Calle Riverside 437 #12, pisos de madera en todo el lugar, ventanas orientadas al sur con vistas al parque, molduras originales, lavadora/secadora en la unidad, $2850/mes, el portero vive en el edificio, contactar a Marcus Realty...",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    // Deploy command for fuzzy search demo
    DemoItem {
        content: "# Enviar servidor API a producción\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/Documentos/proyectos/app-web/src/componentes/autenticacion",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: Refactorizar esta función para mejorar el rendimiento\n// Considerar usar memo para evitar renderizados innecesarios",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://es.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "Recordatorio: Reunión con el equipo mañana a las 10:00 - revisar los requisitos de la nueva función",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"Corregir validación del formulario de inicio de sesión\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "¡Hola mundo!",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    // ClipKitty bullet points (most recent text item)
    DemoItem {
        content: "ClipKitty\n• Cópialo una vez, encuéntralo siempre\n• La búsqueda inteligente perdona tus errores\n• Ve bloques de código completos antes de pegar\n• ⌥Espacio para invocar, teclado primero\n• Tus datos nunca salen de tu Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Simplified Chinese (zh-Hans)
// ============================================================================
pub const DEMO_ITEMS_ZH_HANS: &[DemoItem] = &[
    DemoItem {
        content: "公寓看房笔记：滨江大道437号12室，全屋硬木地板，朝南窗户可观公园景色，原装石膏线，室内洗衣烘干机，$2850/月，管理员住在楼内，联系Marcus房产咨询租约条款...",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# 推送API服务器到生产环境\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "终端",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/文档/项目/网页应用/src/组件/身份验证",
        source_app: "访达",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: 重构此函数以提高性能\n// 考虑使用 memo 来避免不必要的重新渲染",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://zh-hans.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "提醒：明天上午10:00与团队开会 - 审查新功能需求",
        source_app: "备忘录",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"修复登录表单验证问题\"",
        source_app: "终端",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "你好，世界！",
        source_app: "文本编辑",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "终端",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• 复制一次，永久查找\n• 智能搜索容忍拼写错误\n• 粘贴前查看完整代码块\n• ⌥空格唤出，键盘优先\n• 数据永不离开你的 Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Traditional Chinese (zh-Hant)
// ============================================================================
pub const DEMO_ITEMS_ZH_HANT: &[DemoItem] = &[
    DemoItem {
        content: "公寓看房筆記：濱江大道437號12室，全屋硬木地板，朝南窗戶可觀公園景色，原裝石膏線，室內洗衣烘乾機，$2850/月，管理員住在樓內，聯繫Marcus房產諮詢租約條款...",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# 推送API伺服器到生產環境\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "終端機",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/文件/專案/網頁應用程式/src/元件/身份驗證",
        source_app: "尋找器",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: 重構此函式以提升效能\n// 考慮使用 memo 來避免不必要的重新渲染",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://zh-hant.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "提醒：明天上午10:00與團隊開會 - 審查新功能需求",
        source_app: "備忘錄",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"修正登入表單驗證問題\"",
        source_app: "終端機",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "你好，世界！",
        source_app: "文字編輯",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "終端機",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• 複製一次，永遠找得到\n• 智慧搜尋容忍拼字錯誤\n• 貼上前檢視完整程式碼區塊\n• ⌥Space 喚出，鍵盤優先\n• 資料永遠不會離開你的 Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Japanese (ja)
// ============================================================================
pub const DEMO_ITEMS_JA: &[DemoItem] = &[
    DemoItem {
        content: "アパート内覧メモ：リバーサイドドライブ437番地12号室、全室フローリング、南向きの窓から公園を一望、オリジナルの装飾モールディング、室内洗濯乾燥機、$2850/月、管理人常駐、Marcus不動産に契約条件を問い合わせ...",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# APIサーバーを本番環境にプッシュ\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "ターミナル",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/書類/プロジェクト/ウェブアプリ/src/コンポーネント/認証",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: パフォーマンス向上のためこの関数をリファクタリング\n// 不要な再レンダリングを避けるため memo の使用を検討",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://ja.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "リマインダー：明日午前10:00にチームミーティング - 新機能の要件をレビュー",
        source_app: "メモ",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"ログインフォームのバリデーションを修正\"",
        source_app: "ターミナル",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "こんにちは、世界！",
        source_app: "テキストエディット",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "ターミナル",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• 一度コピーすれば、いつでも見つかる\n• スマート検索でタイプミスも許容\n• ペースト前にコードブロック全体を確認\n• ⌥Spaceで呼び出し、キーボード操作\n• データがMacの外に出ることはありません",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Korean (ko)
// ============================================================================
pub const DEMO_ITEMS_KO: &[DemoItem] = &[
    DemoItem {
        content: "아파트 투어 메모: 리버사이드 드라이브 437번지 12호, 전체 원목 바닥, 공원 전망의 남향 창문, 오리지널 크라운 몰딩, 세탁기/건조기 내장, $2850/월, 관리인 상주, Marcus 부동산에 임대 조건 문의...",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# API 서버를 프로덕션에 푸시\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "터미널",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/문서/프로젝트/웹앱/src/컴포넌트/인증",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: 성능 향상을 위해 이 함수 리팩토링\n// 불필요한 재렌더링을 피하기 위해 memo 사용 고려",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://ko.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "알림: 내일 오전 10:00 팀 회의 - 새 기능 요구사항 검토",
        source_app: "메모",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"로그인 폼 유효성 검사 수정\"",
        source_app: "터미널",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "안녕하세요, 세상!",
        source_app: "텍스트 편집기",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "터미널",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• 한 번 복사하면 영원히 검색 가능\n• 스마트 검색으로 오타도 문제없음\n• 붙여넣기 전에 전체 코드 블록 확인\n• ⌥Space로 호출, 키보드 중심\n• 데이터가 Mac 밖으로 나가지 않음",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// French (fr)
// ============================================================================
pub const DEMO_ITEMS_FR: &[DemoItem] = &[
    DemoItem {
        content: "Notes de visite d'appartement : 437 Riverside Dr #12, parquet dans tout l'appartement, fenêtres orientées sud avec vue sur le parc, moulures d'origine, lave-linge/sèche-linge intégré, $2850/mois, gardien sur place, contacter Marcus Realty...",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# Envoyer le serveur API en production\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/Documents/projets/app-web/src/composants/authentification",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: Refactoriser cette fonction pour améliorer les performances\n// Envisager d'utiliser memo pour éviter les rendus inutiles",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://fr.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "Rappel : Réunion d'équipe demain à 10h00 - réviser les exigences de la nouvelle fonctionnalité",
        source_app: "Notes",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"Corriger la validation du formulaire de connexion\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "Bonjour le monde !",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• Copiez une fois, retrouvez toujours\n• La recherche intelligente pardonne les fautes\n• Visualisez les blocs de code avant de coller\n• ⌥Espace pour invoquer, clavier d'abord\n• Vos données ne quittent jamais votre Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// German (de)
// ============================================================================
pub const DEMO_ITEMS_DE: &[DemoItem] = &[
    DemoItem {
        content: "Wohnungsbesichtigung Notizen: Riverside Dr 437 #12, durchgehend Parkettboden, Südfenster mit Parkblick, originale Stuckleisten, Waschmaschine/Trockner in der Wohnung, $2850/Monat, Hausmeister vor Ort, Marcus Realty kontaktieren...",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# API-Server in Produktion schicken\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/Dokumente/projekte/web-app/src/komponenten/authentifizierung",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: Diese Funktion refaktorieren um die Leistung zu verbessern\n// Verwendung von memo in Betracht ziehen um unnötige Renderings zu vermeiden",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://de.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "Erinnerung: Teammeeting morgen um 10:00 Uhr - Anforderungen für neue Funktion überprüfen",
        source_app: "Notizen",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"Login-Formular-Validierung korrigieren\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "Hallo Welt!",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• Einmal kopieren, für immer finden\n• Intelligente Suche verzeiht Tippfehler\n• Code-Blöcke vor dem Einfügen ansehen\n• ⌥Leertaste zum Aufrufen, Tastatur zuerst\n• Deine Daten verlassen nie deinen Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Brazilian Portuguese (pt-BR)
// ============================================================================
pub const DEMO_ITEMS_PT_BR: &[DemoItem] = &[
    DemoItem {
        content: "Notas da visita ao apartamento: Riverside Dr 437 #12, piso de madeira em todo o imóvel, janelas voltadas para o sul com vista para o parque, molduras originais, lavadora/secadora no apartamento, $2850/mês, zelador no local, contatar Marcus Realty...",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# Enviar servidor API para produção\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/Documentos/projetos/app-web/src/componentes/autenticacao",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: Refatorar esta função para melhorar o desempenho\n// Considerar usar memo para evitar renderizações desnecessárias",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://pt-br.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "Lembrete: Reunião com a equipe amanhã às 10h00 - revisar requisitos da nova funcionalidade",
        source_app: "Notas",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"Corrigir validação do formulário de login\"",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "Olá, mundo!",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "Terminal",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• Copie uma vez, encontre para sempre\n• A busca inteligente perdoa erros de digitação\n• Veja blocos de código completos antes de colar\n• ⌥Espaço para chamar, teclado primeiro\n• Seus dados nunca saem do seu Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];

// ============================================================================
// Russian (ru)
// ============================================================================
pub const DEMO_ITEMS_RU: &[DemoItem] = &[
    DemoItem {
        content: "Заметки с осмотра квартиры: Riverside Dr 437 #12, паркет во всех комнатах, окна на юг с видом на парк, оригинальная лепнина, стиральная/сушильная машина в квартире, $2850/мес, консьерж на месте, связаться с Marcus Realty...",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -180 * 24 * 60 * 60,
    },
    DemoItem {
        content: "# Отправить API-сервер в продакшн\ndocker build -t api-server:latest . && \\\ndocker push registry.company.com/api-server:latest && \\\nkubectl set image deployment/api \\\n  api=registry.company.com/api-server:latest \\\n  -n production",
        source_app: "Терминал",
        bundle_id: "com.apple.Terminal",
        offset: -90 * 24 * 60 * 60,
    },
    // Recent items for screenshot visibility
    DemoItem {
        content: "~/Документы/проекты/веб-приложение/src/компоненты/аутентификация",
        source_app: "Finder",
        bundle_id: "com.apple.finder",
        offset: -300,
    },
    DemoItem {
        content: "// TODO: Рефакторинг этой функции для улучшения производительности\n// Рассмотреть использование memo для предотвращения ненужных рендеров",
        source_app: "Visual Studio Code",
        bundle_id: "com.microsoft.VSCode",
        offset: -240,
    },
    DemoItem {
        content: "https://ru.react.dev/reference/react/useState",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -180,
    },
    DemoItem {
        content: "Напоминание: Встреча команды завтра в 10:00 - обсудить требования к новой функции",
        source_app: "Заметки",
        bundle_id: "com.apple.Notes",
        offset: -120,
    },
    DemoItem {
        content: "git commit -m \"Исправить валидацию формы входа\"",
        source_app: "Терминал",
        bundle_id: "com.apple.Terminal",
        offset: -80,
    },
    DemoItem {
        content: "Привет, мир!",
        source_app: "TextEdit",
        bundle_id: "com.apple.TextEdit",
        offset: -45,
    },
    DemoItem {
        content: "npm run build && npm test",
        source_app: "Терминал",
        bundle_id: "com.apple.Terminal",
        offset: -30,
    },
    DemoItem {
        content: "ClipKitty\n• Скопируйте один раз — находите всегда\n• Умный поиск прощает опечатки\n• Просматривайте блоки кода перед вставкой\n• ⌥Пробел для вызова, клавиатура в приоритете\n• Ваши данные никогда не покидают Mac",
        source_app: "Safari",
        bundle_id: "com.apple.Safari",
        offset: -10,
    },
];
