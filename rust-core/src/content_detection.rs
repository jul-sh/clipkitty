//! Content type detection for clipboard items
//!
//! Detects structured content types like URLs, emails, phone numbers, colors, etc.

use crate::models::{ClipboardContent, LinkMetadataState};
use once_cell::sync::Lazy;
use regex::Regex;

/// Detect content type from text, returns the type name as a string
pub fn detect_content_type(text: String) -> String {
    detect_content(&text).database_type().to_string()
}

/// URL detection regex patterns
static URL_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^(https?://[^\s]+|www\.[^\s]+)$").unwrap()
});

/// Email detection regex
static EMAIL_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$").unwrap()
});

/// Phone number detection regex (various formats)
static PHONE_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\+?[\d\s\-().]{7,20}$").unwrap()
});

/// More specific phone validation
static PHONE_DIGITS_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\d").unwrap()
});

/// Hex color regex: #RGB, #RRGGBB, #RRGGBBAA
static HEX_COLOR_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$").unwrap()
});

/// RGB/RGBA color regex: rgb(r, g, b) or rgba(r, g, b, a)
static RGB_COLOR_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)^rgba?\s*\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([\d.]+)\s*)?\)$").unwrap()
});

/// HSL/HSLA color regex: hsl(h, s%, l%) or hsla(h, s%, l%, a)
static HSL_COLOR_REGEX: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)^hsla?\s*\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%\s*(?:,\s*([\d.]+)\s*)?\)$").unwrap()
});

/// Check if a string looks like a URL (public UniFFI version)
pub fn is_url(text: String) -> bool {
    is_url_internal(&text)
}

/// Check if a string looks like a URL (internal version)
fn is_url_internal(text: &str) -> bool {
    let trimmed = text.trim();

    // Basic length and content checks
    if trimmed.len() > 2000 || trimmed.contains('\n') {
        return false;
    }

    // Check common URL prefixes
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return url::Url::parse(trimmed).is_ok();
    }

    if trimmed.starts_with("www.") {
        return url::Url::parse(&format!("https://{}", trimmed)).is_ok();
    }

    // Check with regex for edge cases
    URL_REGEX.is_match(trimmed)
}

/// Check if a string is an email address
pub fn is_email(text: &str) -> bool {
    let trimmed = text.trim();
    EMAIL_REGEX.is_match(trimmed)
}

/// Check if a string looks like a phone number
pub fn is_phone(text: &str) -> bool {
    let trimmed = text.trim();

    // Must match basic phone pattern
    if !PHONE_REGEX.is_match(trimmed) {
        return false;
    }

    // Must have at least 7 digits
    let digit_count = PHONE_DIGITS_REGEX.find_iter(trimmed).count();
    digit_count >= 7 && digit_count <= 15
}

/// Check if a string is a color value
pub fn is_color(text: &str) -> bool {
    let trimmed = text.trim();
    HEX_COLOR_REGEX.is_match(trimmed)
        || RGB_COLOR_REGEX.is_match(trimmed)
        || HSL_COLOR_REGEX.is_match(trimmed)
}

/// Parse a color string to RGBA u32 (0xRRGGBBAA format)
/// Returns None if the string is not a valid color
pub fn parse_color_to_rgba(text: &str) -> Option<u32> {
    let trimmed = text.trim();

    // Try hex color
    if let Some(caps) = HEX_COLOR_REGEX.captures(trimmed) {
        let hex = caps.get(1)?.as_str();
        return Some(parse_hex_color(hex));
    }

    // Try RGB/RGBA
    if let Some(caps) = RGB_COLOR_REGEX.captures(trimmed) {
        let r: u8 = caps.get(1)?.as_str().parse().ok()?;
        let g: u8 = caps.get(2)?.as_str().parse().ok()?;
        let b: u8 = caps.get(3)?.as_str().parse().ok()?;
        let a: u8 = caps.get(4)
            .and_then(|m| m.as_str().parse::<f32>().ok())
            .map(|a| (a.clamp(0.0, 1.0) * 255.0) as u8)
            .unwrap_or(255);
        return Some(((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a as u32));
    }

    // Try HSL/HSLA
    if let Some(caps) = HSL_COLOR_REGEX.captures(trimmed) {
        let h: f32 = caps.get(1)?.as_str().parse().ok()?;
        let s: f32 = caps.get(2)?.as_str().parse::<f32>().ok()? / 100.0;
        let l: f32 = caps.get(3)?.as_str().parse::<f32>().ok()? / 100.0;
        let a: u8 = caps.get(4)
            .and_then(|m| m.as_str().parse::<f32>().ok())
            .map(|a| (a.clamp(0.0, 1.0) * 255.0) as u8)
            .unwrap_or(255);

        let (r, g, b) = hsl_to_rgb(h, s, l);
        return Some(((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a as u32));
    }

    None
}

/// Parse hex color string to RGBA u32
fn parse_hex_color(hex: &str) -> u32 {
    match hex.len() {
        3 => {
            // #RGB -> #RRGGBBFF
            let chars: Vec<char> = hex.chars().collect();
            let r = parse_hex_digit(chars[0]) * 17;
            let g = parse_hex_digit(chars[1]) * 17;
            let b = parse_hex_digit(chars[2]) * 17;
            ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | 0xFF
        }
        6 => {
            // #RRGGBB -> #RRGGBBFF
            let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(0);
            let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(0);
            let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(0);
            ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | 0xFF
        }
        8 => {
            // #RRGGBBAA
            let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(0);
            let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(0);
            let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(0);
            let a = u8::from_str_radix(&hex[6..8], 16).unwrap_or(255);
            ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a as u32)
        }
        _ => 0xFF000000, // Default to black
    }
}

/// Parse a single hex digit
fn parse_hex_digit(c: char) -> u8 {
    match c.to_ascii_lowercase() {
        '0'..='9' => c as u8 - b'0',
        'a'..='f' => c as u8 - b'a' + 10,
        _ => 0,
    }
}

/// Convert HSL to RGB
fn hsl_to_rgb(h: f32, s: f32, l: f32) -> (u8, u8, u8) {
    if s == 0.0 {
        let gray = (l * 255.0) as u8;
        return (gray, gray, gray);
    }

    let h = h / 360.0;
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;

    let r = hue_to_rgb(p, q, h + 1.0 / 3.0);
    let g = hue_to_rgb(p, q, h);
    let b = hue_to_rgb(p, q, h - 1.0 / 3.0);

    ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

fn hue_to_rgb(p: f32, q: f32, mut t: f32) -> f32 {
    if t < 0.0 { t += 1.0; }
    if t > 1.0 { t -= 1.0; }

    if t < 1.0 / 6.0 {
        return p + (q - p) * 6.0 * t;
    }
    if t < 1.0 / 2.0 {
        return q;
    }
    if t < 2.0 / 3.0 {
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    }
    p
}

/// Detect the content type from text
pub fn detect_content(text: &str) -> ClipboardContent {
    let trimmed = text.trim();

    // Check for mailto: URLs first
    if trimmed.to_lowercase().starts_with("mailto:") {
        let address = trimmed.strip_prefix("mailto:")
            .or_else(|| trimmed.strip_prefix("MAILTO:"))
            .unwrap_or(trimmed)
            .split('?')
            .next()
            .unwrap_or(trimmed);
        return ClipboardContent::Email { address: address.to_string() };
    }

    // Check for color values (before URLs since some color formats might look URL-ish)
    if is_color(trimmed) {
        return ClipboardContent::Color { value: trimmed.to_string() };
    }

    // Check for URLs
    if is_url_internal(trimmed) {
        return ClipboardContent::Link {
            url: trimmed.to_string(),
            metadata_state: LinkMetadataState::Pending,
        };
    }

    // Check for email addresses
    if is_email(trimmed) {
        return ClipboardContent::Email { address: trimmed.to_string() };
    }

    // Check for phone numbers
    if is_phone(trimmed) {
        return ClipboardContent::Phone { number: trimmed.to_string() };
    }

    // Default to plain text
    ClipboardContent::Text { value: text.to_string() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_url_detection() {
        assert!(is_url_internal("https://example.com"));
        assert!(is_url_internal("http://example.com/path?query=1"));
        assert!(is_url_internal("www.example.com"));
        assert!(!is_url_internal("not a url"));
        assert!(!is_url_internal("example.com")); // No scheme or www
    }

    #[test]
    fn test_email_detection() {
        assert!(is_email("user@example.com"));
        assert!(is_email("user.name+tag@example.co.uk"));
        assert!(!is_email("not an email"));
        assert!(!is_email("@example.com"));
    }

    #[test]
    fn test_phone_detection() {
        assert!(is_phone("+1 (555) 123-4567"));
        assert!(is_phone("555-123-4567"));
        assert!(is_phone("5551234567"));
        assert!(!is_phone("123")); // Too short
        assert!(!is_phone("not a phone"));
    }

    #[test]
    fn test_color_detection_hex() {
        assert!(is_color("#fff"));
        assert!(is_color("#FFF"));
        assert!(is_color("#ffffff"));
        assert!(is_color("#FFFFFF"));
        assert!(is_color("#ff5733"));
        assert!(is_color("#FF5733"));
        assert!(is_color("#ff5733aa"));
        assert!(is_color("#FF5733AA"));
        assert!(!is_color("#ff")); // Too short
        assert!(!is_color("#fffffff")); // Wrong length
        assert!(!is_color("fff")); // No hash
    }

    #[test]
    fn test_color_detection_rgb() {
        assert!(is_color("rgb(255, 128, 0)"));
        assert!(is_color("RGB(255, 128, 0)"));
        assert!(is_color("rgb(255,128,0)"));
        assert!(is_color("rgba(255, 128, 0, 0.5)"));
        assert!(is_color("rgba(255, 128, 0, 1)"));
        // Note: regex allows 256 (1-3 digits), actual parsing will clamp/handle it
        assert!(is_color("rgb(256, 128, 0)"));
    }

    #[test]
    fn test_color_detection_hsl() {
        assert!(is_color("hsl(120, 50%, 50%)"));
        assert!(is_color("HSL(120, 50%, 50%)"));
        assert!(is_color("hsla(120, 50%, 50%, 0.5)"));
        assert!(!is_color("hsl(120, 50, 50)")); // Missing %
    }

    #[test]
    fn test_parse_hex_color() {
        // #RGB
        assert_eq!(parse_color_to_rgba("#fff"), Some(0xFFFFFFFF));
        assert_eq!(parse_color_to_rgba("#000"), Some(0x000000FF));
        assert_eq!(parse_color_to_rgba("#f00"), Some(0xFF0000FF));

        // #RRGGBB
        assert_eq!(parse_color_to_rgba("#ffffff"), Some(0xFFFFFFFF));
        assert_eq!(parse_color_to_rgba("#000000"), Some(0x000000FF));
        assert_eq!(parse_color_to_rgba("#ff5733"), Some(0xFF5733FF));

        // #RRGGBBAA
        assert_eq!(parse_color_to_rgba("#ffffff00"), Some(0xFFFFFF00));
        assert_eq!(parse_color_to_rgba("#ff573380"), Some(0xFF573380));
    }

    #[test]
    fn test_parse_rgb_color() {
        assert_eq!(parse_color_to_rgba("rgb(255, 255, 255)"), Some(0xFFFFFFFF));
        assert_eq!(parse_color_to_rgba("rgb(0, 0, 0)"), Some(0x000000FF));
        assert_eq!(parse_color_to_rgba("rgb(255, 87, 51)"), Some(0xFF5733FF));
        assert_eq!(parse_color_to_rgba("rgba(255, 87, 51, 0.5)"), Some(0xFF57337F)); // ~0.5 * 255 = 127
    }

    #[test]
    fn test_parse_hsl_color() {
        // Pure red: hsl(0, 100%, 50%)
        let red = parse_color_to_rgba("hsl(0, 100%, 50%)").unwrap();
        assert_eq!((red >> 24) & 0xFF, 255); // R
        assert_eq!((red >> 16) & 0xFF, 0);   // G
        assert_eq!((red >> 8) & 0xFF, 0);    // B
        assert_eq!(red & 0xFF, 255);          // A

        // Pure green: hsl(120, 100%, 50%)
        let green = parse_color_to_rgba("hsl(120, 100%, 50%)").unwrap();
        assert_eq!((green >> 24) & 0xFF, 0);   // R
        assert_eq!((green >> 16) & 0xFF, 255); // G (approximately, due to rounding)
        assert_eq!((green >> 8) & 0xFF, 0);    // B
    }

    #[test]
    fn test_content_detection_color() {
        // Hex color
        if let ClipboardContent::Color { value } = detect_content("#FF5733") {
            assert_eq!(value, "#FF5733");
        } else {
            panic!("Expected Color content");
        }

        // RGB color
        if let ClipboardContent::Color { value } = detect_content("rgb(255, 87, 51)") {
            assert_eq!(value, "rgb(255, 87, 51)");
        } else {
            panic!("Expected Color content");
        }
    }

    #[test]
    fn test_content_detection() {
        // URL
        if let ClipboardContent::Link { url, .. } = detect_content("https://github.com") {
            assert_eq!(url, "https://github.com");
        } else {
            panic!("Expected Link content");
        }

        // Email
        if let ClipboardContent::Email { address } = detect_content("user@example.com") {
            assert_eq!(address, "user@example.com");
        } else {
            panic!("Expected Email content");
        }

        // Mailto
        if let ClipboardContent::Email { address } = detect_content("mailto:user@example.com") {
            assert_eq!(address, "user@example.com");
        } else {
            panic!("Expected Email content from mailto");
        }

        // Phone
        if let ClipboardContent::Phone { number } = detect_content("+1 555-123-4567") {
            assert_eq!(number, "+1 555-123-4567");
        } else {
            panic!("Expected Phone content");
        }

        // Plain text
        if let ClipboardContent::Text { value } = detect_content("Hello World") {
            assert_eq!(value, "Hello World");
        } else {
            panic!("Expected Text content");
        }
    }
}
