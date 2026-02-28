# ClipKitty Performance Investigation

## Problem
UI freezes (up to ~400ms) when typing rapidly in the search field.

## Profiling Method
- Instruments with SwiftUI instrument
- Exported trace data via `xctrace export`
- Analyzed `swiftui-updates` schema for slow operations

## Findings

### Slowest Operations Captured

| Duration | Component | Description |
|----------|-----------|-------------|
| 398.64ms | EditableTextPreview | Full text layout recalculation |
| 77.01ms | EditableTextPreview | Text storage update |
| 75.59ms | LayoutPositionQuery | Layout triggered by text change |
| 73.75ms | EditableTextPreview | Item switch with large text |
| 70.02ms | ItemRow/TupleView | View body updates |

### Root Cause

**`NSTextStorage.setAttributedString()` triggers full text re-layout**

In `EditableTextPreview.updateNSView()` (ContentView.swift:1779, 1786):

```swift
let attributed = NSAttributedString(string: currentText, attributes: typingAttrs)
textView.textStorage?.setAttributedString(attributed)
```

This is called:
1. When the selected item changes
2. When font size changes
3. When text differs from current (and not editing)

For large clipboard items (50KB+), `setAttributedString` forces NSTextView to:
- Parse the entire string
- Calculate glyph positions for all characters
- Compute line breaks and layout
- This blocks the main thread for 70-400ms

### Trigger Chain

```
User types in search
    → ClipboardStore.DisplayState changes
        → SwiftUI re-renders affected views
            → List selection changes to new filtered item
                → EditableTextPreview.updateNSView called
                    → textStorage.setAttributedString(newText)
                        → Full NSLayoutManager layout pass (BLOCKING)
```

### Secondary Issues

1. **Highlight updates also replaced full text** - `applyHighlights()` was creating a new `NSMutableAttributedString` and calling `setAttributedString()` on every highlight change

2. **Layout computation for scroll** - `ensureLayout(forGlyphRange:)` called for the entire document when scrolling to highlights

## Fixes Applied

### 1. In-place highlight updates (applyHighlights)
Instead of replacing entire attributed string:
```swift
// Before (slow)
let attributed = NSMutableAttributedString(string: currentText, attributes: [...])
textStorage.setAttributedString(attributed)

// After (fast)
textStorage.beginEditing()
textStorage.removeAttribute(.backgroundColor, range: fullRange)
textStorage.removeAttribute(.underlineStyle, range: fullRange)
// Add new highlights...
textStorage.endEditing()
```

### 2. Async loading for large text (updateNSView)
For items >50KB, show truncated preview immediately and load full text async:
```swift
if isLargeText && itemChanged {
    // Show first 10KB immediately
    let truncated = String(currentText.prefix(10_000))
    textStorage.setAttributedString(truncatedAttr)

    // Load full text after UI settles
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        textStorage.setAttributedString(fullAttr)
    }
}
```

## Recommendations

1. **Consider TextKit 2** - NSTextLayoutManager (macOS 12+) has better incremental layout support

2. **Virtualized text rendering** - Only render visible portion of large text, similar to how List virtualizes rows

3. **Background text processing** - Move attributed string creation off main thread (though `setAttributedString` must be called on main)

4. **Limit preview size** - For very large items (>100KB), always show truncated preview with "Show full content" button
