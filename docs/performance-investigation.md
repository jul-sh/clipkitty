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

**TextKit 1's `NSLayoutManager` performs full document layout**

With TextKit 1, any change to `NSTextStorage` triggers a complete re-layout of the entire document. For large clipboard items (50KB+), this blocks the main thread for 70-400ms.

The trigger chain:
```
User types in search
    → ClipboardStore.DisplayState changes
        → SwiftUI re-renders affected views
            → List selection changes to new filtered item
                → NSViewRepresentable.updateNSView called
                    → textStorage.setAttributedString(newText)
                        → Full NSLayoutManager layout pass (BLOCKING)
```

## Solution: TextKit 2

Migrated from TextKit 1 (`NSLayoutManager`) to TextKit 2 (`NSTextLayoutManager`).

### Key Differences

| TextKit 1 | TextKit 2 |
|-----------|-----------|
| Full document layout on any change | Viewport-based layout (only visible text) |
| Highlight changes trigger re-layout | Rendering attributes don't trigger layout |
| Synchronous layout computation | Incremental/lazy layout |

### Implementation

1. **NSTextView with TextKit 2** - Use `NSTextView(usingTextLayoutManager: true)` to opt into TextKit 2

2. **Rendering attributes for highlights** - Use `textLayoutManager.addRenderingAttribute()` instead of modifying text storage. Rendering attributes only affect drawing, not layout.

```swift
// TextKit 2: Non-blocking highlight updates
textLayoutManager.removeRenderingAttribute(.backgroundColor, for: documentRange)
textLayoutManager.addRenderingAttribute(.backgroundColor, value: color, for: highlightRange)
```

3. **Viewport-based layout** - TextKit 2's `NSTextViewportLayoutController` automatically manages which text fragments are laid out based on the visible area.

### Result

- No more 70-400ms freezes when typing in search
- Smooth scrolling through large documents
- Instant highlight updates without re-layout
