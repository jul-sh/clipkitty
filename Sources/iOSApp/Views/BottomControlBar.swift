import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct BottomControlBar: View {
    @Binding var isSearchActive: Bool
    @Binding var isFilterPickerPresented: Bool
    @Binding var isAddFlowPresented: Bool

    @Environment(BrowserViewModel.self) private var viewModel

    var body: some View {
        HStack(spacing: 0) {
            searchButton
            Spacer()
            filterButton
            Spacer()
            addButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: - Search

    private var searchButton: some View {
        Button {
            isSearchActive.toggle()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
    }

    // MARK: - Filter

    private var filterButton: some View {
        Button {
            isFilterPickerPresented = true
        } label: {
            Text(filterLabel)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter: \(filterLabel)")
        .accessibilityHint("Open filter picker")
    }

    // MARK: - Add

    private var addButton: some View {
        Button {
            isAddFlowPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add new item")
    }

    // MARK: - Filter label

    private var filterLabel: String {
        if viewModel.selectedTagFilter == .bookmark {
            return "Bookmarks"
        }

        switch viewModel.contentTypeFilter {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        case .links: return "Links"
        case .colors: return "Colors"
        case .files: return "Files"
        }
    }
}
