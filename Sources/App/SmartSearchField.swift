import SwiftUI
import ClipKittyRust

/// Custom search field with inline filter tag support and autocomplete suggestions
struct SmartSearchField: View {
    @Binding var textQuery: String
    @Binding var activeFilter: ContentTypeFilter?
    @Binding var autocompleteState: AutocompleteState

    let onMoveSelection: (Int) -> Void
    let onConfirmSelection: () -> Void
    let onDismiss: () -> Void
    let onShowActions: () -> Void
    let onShowDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Filter tag (if active)
            if let filter = activeFilter,
               let suggestion = FilterSuggestion.suggestion(for: filter) {
                FilterTagView(
                    suggestion: suggestion,
                    onDelete: {
                        activeFilter = nil
                    }
                )
            }

            // Text input
            TextField("Clipboard History Search", text: $textQuery)
                .textFieldStyle(.plain)
                .font(.custom(FontManager.sansSerif, size: 17))
                .tint(.primary)
                .accessibilityIdentifier("SearchField")
                .onChange(of: textQuery) { _, newValue in
                    processInput(newValue)
                }
                .onKeyPress(.upArrow) {
                    handleUpArrow()
                }
                .onKeyPress(.downArrow) {
                    handleDownArrow()
                }
                .onKeyPress(.return, phases: .down) { keyPress in
                    handleReturn(modifiers: keyPress.modifiers)
                }
                .onKeyPress(.escape) {
                    handleEscape()
                }
                .onKeyPress(.tab) {
                    handleTab()
                }
                .onKeyPress(.deleteForward) {
                    onShowDelete()
                    return .handled
                }
        }
    }

    // MARK: - Input Processing

    private func processInput(_ input: String) {
        if activeFilter != nil {
            // Filter already active, don't show autocomplete for filter names
            autocompleteState = .hidden
        } else {
            // Check for filter suggestions
            let suggestions = FilterSuggestion.suggestions(for: input)
            if input.isEmpty || suggestions.isEmpty {
                autocompleteState = .hidden
            } else {
                // Show autocomplete with matching suggestions
                autocompleteState = .visible(suggestions: suggestions, highlightedIndex: 0)
            }
        }
    }

    // MARK: - Keyboard Handlers

    private func handleUpArrow() -> KeyPress.Result {
        switch autocompleteState {
        case .visible(let suggestions, let index):
            let newIndex = index > 0 ? index - 1 : suggestions.count - 1
            autocompleteState = .visible(suggestions: suggestions, highlightedIndex: newIndex)
            return .handled
        case .hidden:
            onMoveSelection(-1)
            return .handled
        }
    }

    private func handleDownArrow() -> KeyPress.Result {
        switch autocompleteState {
        case .visible(let suggestions, let index):
            let newIndex = index < suggestions.count - 1 ? index + 1 : 0
            autocompleteState = .visible(suggestions: suggestions, highlightedIndex: newIndex)
            return .handled
        case .hidden:
            onMoveSelection(1)
            return .handled
        }
    }

    private func handleReturn(modifiers: EventModifiers) -> KeyPress.Result {
        // Check for Option+Return to show actions
        if modifiers.contains(.option) {
            onShowActions()
            return .handled
        }

        // If autocomplete is visible, select the highlighted suggestion
        if case .visible(let suggestions, let index) = autocompleteState {
            let suggestion = suggestions[index]
            selectFilterSuggestion(suggestion)
            return .handled
        }

        // No autocomplete visible - confirm selection in results list
        onConfirmSelection()
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        if case .visible = autocompleteState {
            autocompleteState = .hidden
            return .handled
        }
        onDismiss()
        return .handled
    }

    private func handleTab() -> KeyPress.Result {
        if case .visible(let suggestions, let index) = autocompleteState {
            // Tab acts like Return for autocomplete selection
            let suggestion = suggestions[index]
            selectFilterSuggestion(suggestion)
            return .handled
        }
        // Tab with no autocomplete does nothing special
        return .ignored
    }

    // MARK: - Selection

    private func selectFilterSuggestion(_ suggestion: FilterSuggestion) {
        activeFilter = suggestion.filter
        textQuery = "" // Clear the text that matched the filter name
        autocompleteState = .hidden
    }
}
