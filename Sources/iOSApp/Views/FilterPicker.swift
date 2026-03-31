import ClipKittyRust
import ClipKittyShared
import SwiftUI

struct FilterPicker: View {
    @Environment(BrowserViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    private var activeFilter: FilterOption {
        if viewModel.selectedTagFilter == .bookmark {
            return .bookmarks
        }
        switch viewModel.contentTypeFilter {
        case .all, .files: return .all
        case .text: return .text
        case .images: return .images
        case .links: return .links
        case .colors: return .colors
        }
    }

    var body: some View {
        NavigationStack {
            List(FilterOption.allCases) { option in
                Button {
                    applyFilter(option)
                    HapticFeedback.selection()
                    dismiss()
                } label: {
                    HStack {
                        Label(option.title, systemImage: option.icon)
                            .foregroundColor(option == activeFilter ? Color.accentColor : Color.primary)
                        Spacer()
                        if option == activeFilter {
                            Image(systemName: "checkmark")
                                .foregroundColor(Color.accentColor)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func applyFilter(_ option: FilterOption) {
        switch option {
        case .all:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.all)
        case .bookmarks:
            viewModel.setTagFilter(.bookmark)
        case .text:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.text)
        case .images:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.images)
        case .links:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.links)
        case .colors:
            viewModel.setTagFilter(nil)
            viewModel.setContentTypeFilter(.colors)
        }
    }
}

private enum FilterOption: String, CaseIterable, Identifiable {
    case all
    case bookmarks
    case text
    case images
    case links
    case colors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .bookmarks: return "Bookmarks"
        case .text: return "Text"
        case .images: return "Images"
        case .links: return "Links"
        case .colors: return "Colors"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .bookmarks: return "bookmark.fill"
        case .text: return "doc.text"
        case .images: return "photo"
        case .links: return "link"
        case .colors: return "paintpalette"
        }
    }
}
