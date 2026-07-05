import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct BrowserResultsList: View {
    @Bindable var viewModel: BrowserViewModel
    let displayVersion: Int
    let focusSearchField: () -> Void

    private let matchDataPrefetchBuffer = 20
    @State private var lastItemsSignature: [String] = []
    @State private var contextMenuItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            if let suggestion = viewModel.pendingFilterSuggestion {
                PendingFilterChip(
                    title: viewModel.filterDescriptor(for: suggestion.kind).title,
                    selection: {
                        switch viewModel.keyboardTarget {
                        case .pendingFilterChip:
                            return viewModel.hasUserNavigated ? .accentSelected : .selected
                        case .results:
                            return .unselected
                        }
                    }(),
                    onActivate: {
                        viewModel.applyPendingFilterSuggestion()
                        focusSearchField()
                    }
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            resultsList
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.pendingFilterSuggestion?.kind)
        // Locale-invariant automation signal: which filter's results are on
        // screen and whether they are settled. Screenshot and video capture
        // wait on the "loaded" form instead of racing row labels.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ResultsState_\(viewModel.activeFilterKind.rawValue)_\(contentPhaseIdentifier)")
    }

    private var contentPhaseIdentifier: String {
        if case .loaded = viewModel.contentState {
            return "loaded"
        }
        return "loading"
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.displayRows) { row in
                    let index = viewModel.indexOfItem(row.metadata.itemId) ?? 0
                    ItemRow(
                        metadata: row.metadata,
                        presentation: row.presentation,
                        // While the pending chip is the keyboard target, no row
                        // may read as the active selection even though one stays
                        // selected underneath for when the keyboard returns.
                        isSelected: {
                            switch viewModel.keyboardTarget {
                            case .pendingFilterChip: return false
                            case .results: return row.metadata.itemId == viewModel.selectedItemId
                            }
                        }(),
                        isContextMenuTargeted: row.metadata.itemId == contextMenuItemId,
                        hasUserNavigated: viewModel.hasUserNavigated,
                        hasPendingEdit: {
                            if case let .dirty(dirtyId, _) = viewModel.editSession, dirtyId == row.metadata.itemId {
                                return true
                            }
                            return false
                        }(),
                        onTap: {
                            viewModel.select(itemId: row.metadata.itemId, origin: .click)
                            focusSearchField()
                        },
                        contextMenuActions: BrowserActionItem.items(for: row.metadata.tags),
                        onContextMenuAction: { action in
                            viewModel.performAction(
                                action.browserAction,
                                itemId: row.metadata.itemId,
                                dismissOverlay: {}
                            )
                        },
                        onContextMenuDelete: {
                            viewModel.deleteItem(itemId: row.metadata.itemId)
                        },
                        onContextMenuShow: {
                            contextMenuItemId = row.metadata.itemId
                            viewModel.closeOverlay()
                        },
                        onContextMenuHide: {
                            if contextMenuItemId == row.metadata.itemId {
                                contextMenuItemId = nil
                            }
                        }
                    )
                    .onAppear { onItemAppear(index: index) }
                    .accessibilityIdentifier("ItemRow_\(index)")
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(nil, value: viewModel.itemIds)
            .modifier(HideScrollIndicatorsWhenOverlay(displayVersion: displayVersion))
            .onChange(of: viewModel.searchText) { _, _ in
                if let firstItemId = viewModel.itemIds.first {
                    proxy.scrollTo(firstItemId, anchor: .top)
                }
            }
            .onChange(of: viewModel.selectedItemId) { oldItemId, newItemId in
                guard let newItemId else { return }
                let currentSignature = viewModel.itemIds
                let itemsChanged = currentSignature != lastItemsSignature
                if itemsChanged {
                    lastItemsSignature = currentSignature
                }

                // A click lands on a row the user can already see. Scrolling
                // it to the center would yank the list under their cursor,
                // so we leave the viewport alone. Keyboard nav and programmatic
                // selection changes still scroll so the new selection is visible.
                guard viewModel.selection.origin?.requiresScrollIntoView ?? true else {
                    return
                }

                let oldIndex = indexForItem(oldItemId)
                let newIndex = indexForItem(newItemId)
                let isBigJump = {
                    guard let oldIndex, let newIndex else { return false }
                    return abs(newIndex - oldIndex) > 1
                }()

                if !itemsChanged && isBigJump {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newItemId, anchor: .center)
                    }
                } else {
                    proxy.scrollTo(newItemId, anchor: .center)
                }
            }
            .onAppear {
                lastItemsSignature = viewModel.itemIds
            }
        }
    }

    private func indexForItem(_ itemId: String?) -> Int? {
        viewModel.indexOfItem(itemId)
    }

    private func onItemAppear(index: Int) {
        let startIndex = max(0, index - matchDataPrefetchBuffer)
        let endIndex = min(viewModel.itemCount - 1, index + matchDataPrefetchBuffer)
        guard startIndex <= endIndex else { return }
        let idsToLoad = (startIndex ... endIndex).compactMap { idx in
            viewModel.itemIds.indices.contains(idx) ? viewModel.itemIds[idx] : nil
        }
        viewModel.loadMatchedExcerptsForItems(idsToLoad)
    }
}

/// The typed-filter suggestion chip revealed above the result rows. The
/// results keep the keyboard while it is visible; Up from the first row
/// addresses the chip, Enter then applies the filter, Down returns to the
/// results, and clicking commits directly. Over an EMPTY result list the
/// chip takes the keyboard automatically so Return isn't inert.
///
/// Selection mirrors the row rule: the accent fill is earned by user
/// navigation (Up onto the chip), while an automatic keyboard grant over an
/// empty list renders the neutral selected gray — exactly how a selected row
/// shows accent only once the user has navigated.
private struct PendingFilterChip: View {
    /// How the chip renders relative to the keyboard, mirroring row
    /// selection: `selected` is the automatic grant (gray), `accentSelected`
    /// is user navigation onto the chip.
    enum Selection {
        case unselected
        case selected
        case accentSelected
    }

    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let selection: Selection
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 5) {
                Text(String(localized: "filter:"))
                    .font(settings.appFont(size: settings.scaled(11)))
                    .foregroundStyle(prefixColor)
                Text(title)
                    .font(settings.appFont(size: settings.scaled(12), weight: .semibold))
                    .foregroundStyle(titleColor)
                switch selection {
                case .unselected:
                    EmptyView()
                case .selected, .accentSelected:
                    Text(verbatim: "⏎")
                        .font(settings.appFont(size: settings.scaled(10)))
                        .foregroundStyle(hintColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("PendingFilterChip")
        .accessibilityAddTraits({
            switch selection {
            case .unselected: return []
            case .selected, .accentSelected: return .isSelected
            }
        }())
    }

    private var fillColor: Color {
        switch selection {
        case .unselected: return Color.primary.opacity(0.04)
        case .selected: return Color.primary.opacity(0.225)
        case .accentSelected: return Color.selectionBackground
        }
    }

    private var borderColor: Color {
        switch selection {
        case .unselected: return Color.primary.opacity(0.1)
        case .selected, .accentSelected: return Color.clear
        }
    }

    private var titleColor: Color {
        switch selection {
        case .unselected: return .secondary
        case .selected: return .primary
        case .accentSelected: return .white
        }
    }

    private var prefixColor: Color {
        switch selection {
        case .unselected, .selected: return .secondary
        case .accentSelected: return Color.white.opacity(0.7)
        }
    }

    private var hintColor: Color {
        switch selection {
        case .unselected, .selected: return Color.secondary.opacity(0.7)
        case .accentSelected: return Color.white.opacity(0.7)
        }
    }
}
