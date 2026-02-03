//! Content type detection for clipboard items
//!
//! Detects structured content types like URLs, emails, phone numbers, colors, etc.

use crate::interface::{ClipboardContent, LinkMetadataState};
use once_cell::sync::Lazy;
use regex::Regex;

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

/// Check if a string looks like a URL
fn is_valid_url(text: &str) -> bool {
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
fn is_email(text: &str) -> bool {
    let trimmed = text.trim();
    EMAIL_REGEX.is_match(trimmed)
}

/// Check if a string looks like a phone number
fn is_phone(text: &str) -> bool {
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
/// Supports hex (#RGB, #RRGGBB, #RRGGBBAA), rgb(), rgba(), hsl(), hsla()
fn is_color(text: &str) -> bool {
    let trimmed = text.trim();
    let lower = trimmed.to_lowercase();
    // Only accept strings that look like color values (not arbitrary words like "red")
    if trimmed.starts_with('#') || lower.starts_with("rgb") || lower.starts_with("hsl") {
        csscolorparser::parse(trimmed).is_ok()
    } else {
        false
    }
}

/// Parse a color string to RGBA u32 (0xRRGGBBAA format)
/// Returns None if the string is not a valid color
pub fn parse_color_to_rgba(text: &str) -> Option<u32> {
    let trimmed = text.trim();
    let lower = trimmed.to_lowercase();
    // Only parse explicit color formats (hex, rgb, hsl) not named colors
    if !trimmed.starts_with('#') && !lower.starts_with("rgb") && !lower.starts_with("hsl") {
        return None;
    }
    let color = csscolorparser::parse(trimmed).ok()?;
    let [r, g, b, a] = color.to_rgba8();
    Some(((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a as u32))
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
    if is_valid_url(trimmed) {
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
        assert!(is_valid_url("https://example.com"));
        assert!(is_valid_url("http://example.com/path?query=1"));
        assert!(is_valid_url("www.example.com"));
        assert!(!is_valid_url("not a url"));
        assert!(!is_valid_url("example.com")); // No scheme or www
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
