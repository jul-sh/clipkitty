import ClipKittyRust
import SwiftUI

struct BrowserResultsList: View {
    @Bindable var viewModel: BrowserViewModel
    let displayVersion: Int
    let focusSearchField: () -> Void

    private let matchDataPrefetchBuffer = 20
    @State private var lastItemsSignature: [Int64] = []
    @State private var contextMenuItemId: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.displayRows.enumerated()), id: \.element.metadata.itemId) { index, row in
                    ItemRow(
                        metadata: row.metadata,
                        rowDecoration: row.rowDecoration,
                        isSelected: row.metadata.itemId == viewModel.selectedItemId,
                        isContextMenuTargeted: row.metadata.itemId == contextMenuItemId,
                        hasUserNavigated: viewModel.hasUserNavigated,
                        hasPendingEdit: viewModel.hasPendingEdit(for: row.metadata.itemId),
                        onTap: {
                            viewModel.select(itemId: row.metadata.itemId, origin: .user)
                            focusSearchField()
                        },
                        contextMenuActions: BrowserActionItem.items(for: row.metadata.tags),
                        onContextMenuAction: { action in
                            viewModel.performAction(
                                action,
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

    private func indexForItem(_ itemId: Int64?) -> Int? {
        viewModel.indexOfItem(itemId)
    }

    private func onItemAppear(index: Int) {
        let startIndex = max(0, index - matchDataPrefetchBuffer)
        let endIndex = min(viewModel.itemCount - 1, index + matchDataPrefetchBuffer)
        guard startIndex <= endIndex else { return }
        let idsToLoad = (startIndex ... endIndex).compactMap { idx in
            viewModel.itemIds.indices.contains(idx) ? viewModel.itemIds[idx] : nil
        }
        viewModel.loadRowDecorationsForItems(idsToLoad)
    }
}
