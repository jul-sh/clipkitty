//! Test for long content highlighting issue
//! Issue: Highlight ranges computed incorrectly for long text

mod test_data;

/// Simple tokenizer to simulate what Rust does
fn tokenize_words(content: &str) -> Vec<(usize, usize, String)> {
    let chars: Vec<char> = content.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_whitespace() {
            i += 1;
            continue;
        }
        let start = i;
        if chars[i].is_alphanumeric() {
            while i < chars.len() && chars[i].is_alphanumeric() {
                i += 1;
            }
        } else {
            while i < chars.len() && !chars[i].is_alphanumeric() && !chars[i].is_whitespace() {
                i += 1;
            }
        }
        let token: String = chars[start..i].iter().collect();
        tokens.push((start, i, token));
    }
    tokens
}

/// Convert char index to UTF-16 code unit index
fn char_to_utf16_index(content: &str, char_index: usize) -> usize {
    content.chars()
        .take(char_index)
        .map(|c| c.len_utf16())
        .sum()
}

/// Check if a query word matches a doc word
fn word_matches(qw: &str, dw: &str) -> bool {
    dw == qw || (qw.len() >= 2 && dw.starts_with(qw))
}

#[test]
fn test_char_vs_utf16_position_mismatch() {
    let content = test_data::LONG_TEST_CONTENT;

    println!("\n=== Char vs UTF-16 Position Analysis ===");
    println!("Content char count: {}", content.chars().count());
    println!("Content UTF-16 length: {}", content.encode_utf16().count());

    // Find where emojis/special chars cause drift
    let mut char_idx = 0usize;
    let mut utf16_idx = 0usize;
    let mut drift_points = Vec::new();

    for ch in content.chars() {
        let utf16_len = ch.len_utf16();
        if utf16_len != 1 {
            drift_points.push((char_idx, utf16_idx, ch, utf16_len));
        }
        char_idx += 1;
        utf16_idx += utf16_len;
    }

    println!("\nFound {} characters that cause position drift:", drift_points.len());
    for (ci, ui, ch, len) in drift_points.iter().take(20) {
        println!("  Char {} / UTF16 {}: '{}' (U+{:04X}) takes {} UTF-16 units",
                 ci, ui, ch, *ch as u32, len);
    }
    if drift_points.len() > 20 {
        println!("  ... and {} more", drift_points.len() - 20);
    }

    // Calculate total drift
    let total_char_count = content.chars().count();
    let total_utf16_count: usize = content.encode_utf16().count();
    let total_drift = total_utf16_count as i64 - total_char_count as i64;
    println!("\nTotal drift: {} positions", total_drift);

    // Now find "Files" and check positions
    println!("\n=== Finding 'Files' word ===");
    let content_lower = content.to_lowercase();
    let doc_words = tokenize_words(&content_lower);

    for (char_start, char_end, word) in &doc_words {
        if word == "files" {
            let utf16_start = char_to_utf16_index(&content_lower, *char_start);
            let utf16_end = char_to_utf16_index(&content_lower, *char_end);

            // Extract text using both index types
            let chars: Vec<char> = content.chars().collect();
            let from_char_idx: String = chars[*char_start..*char_end].iter().collect();

            // For UTF-16, we need to use the original string
            let utf16_units: Vec<u16> = content.encode_utf16().collect();
            let from_utf16: String = if utf16_end <= utf16_units.len() {
                String::from_utf16(&utf16_units[utf16_start..utf16_end]).unwrap_or("ERROR".to_string())
            } else {
                "OUT OF BOUNDS".to_string()
            };

            let drift = utf16_start as i64 - *char_start as i64;

            println!("'files' at char {}-{} / UTF16 {}-{} (drift: {})",
                     char_start, char_end, utf16_start, utf16_end, drift);
            println!("  From char indices: '{}'", from_char_idx);
            println!("  From UTF16 indices: '{}'", from_utf16);

            if drift != 0 {
                // Show what Swift would extract using char indices on UTF-16 string
                let utf16_len = utf16_units.len();
                let wrong_end = (*char_end).min(utf16_len);
                let wrong_text = if *char_start < utf16_len && wrong_end <= utf16_len {
                    String::from_utf16(&utf16_units[*char_start..wrong_end]).unwrap_or("ERROR".to_string())
                } else {
                    "OUT OF BOUNDS".to_string()
                };
                println!("  ⚠️  Swift using char indices on UTF16: '{}'", wrong_text);
            }
        }
    }
}

#[test]
fn test_find_iles_location() {
    let content = test_data::LONG_TEST_CONTENT;

    println!("\n=== Finding where 'iles' appears ===");

    // Find all occurrences of "iles" in the content
    for (byte_idx, _) in content.to_lowercase().match_indices("iles") {
        let char_pos = content[..byte_idx].chars().count();
        let context_start = byte_idx.saturating_sub(30);
        let context_end = (byte_idx + 40).min(content.len());

        // Find safe UTF-8 boundaries
        let mut start = context_start;
        while start > 0 && !content.is_char_boundary(start) {
            start -= 1;
        }
        let mut end = context_end;
        while end < content.len() && !content.is_char_boundary(end) {
            end += 1;
        }

        let context = &content[start..end];
        println!("\nFound 'iles' at char {}: ...{}...",
                 char_pos, context.replace('\n', "↵"));
    }
}

#[test]
fn test_example3_files_position() {
    let content = test_data::LONG_TEST_CONTENT;

    println!("\n=== Example 3: Finding Large Files analysis ===");

    // Find "### Example 3: Finding Large Files"
    if let Some(byte_idx) = content.find("### Example 3: Finding Large Files") {
        let char_idx = content[..byte_idx].chars().count();
        let utf16_idx = content[..byte_idx].encode_utf16().count();

        println!("'### Example 3: Finding Large Files' found at:");
        println!("  Byte index: {}", byte_idx);
        println!("  Char index: {}", char_idx);
        println!("  UTF-16 index: {}", utf16_idx);
        println!("  Drift (UTF16 - Char): {}", utf16_idx as i64 - char_idx as i64);

        // Find "Files" within this line
        let files_offset = "### Example 3: Finding Large ".len();
        let files_byte = byte_idx + files_offset;
        let files_char = content[..files_byte].chars().count();
        let files_utf16 = content[..files_byte].encode_utf16().count();

        println!("\n'Files' (in this line) is at:");
        println!("  Char index: {}", files_char);
        println!("  UTF-16 index: {}", files_utf16);
        println!("  Drift: {}", files_utf16 as i64 - files_char as i64);

        // If Swift uses char index on NSString (UTF-16), what would it get?
        let utf16_units: Vec<u16> = content.encode_utf16().collect();
        let files_len = 5; // "Files"
        let wrong_text = String::from_utf16(&utf16_units[files_char..files_char + files_len])
            .unwrap_or("ERROR".to_string());

        println!("\n⚠️  If Swift uses Rust's char index ({}) on NSString:", files_char);
        println!("   It would extract: '{}'", wrong_text);

        // What SHOULD it get using UTF-16 index?
        let correct_text = String::from_utf16(&utf16_units[files_utf16..files_utf16 + files_len])
            .unwrap_or("ERROR".to_string());
        println!("   It SHOULD extract (using UTF-16 index {}): '{}'", files_utf16, correct_text);
    }
}
