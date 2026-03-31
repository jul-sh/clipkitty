import ClipKittyShared
import SwiftUI

struct SearchOverlay: View {
    @Environment(BrowserViewModel.self) private var viewModel
    @Binding var isPresented: Bool
    @State private var searchText: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search clipboard...", text: $searchText)
                        .focused($isFieldFocused)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onChange(of: searchText) { _, newValue in
                            viewModel.updateSearchText(newValue)
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            viewModel.updateSearchText("")
                        } label: {
                            Image(systemName: "x.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismissSearch()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            isFieldFocused = true
        }
    }

    private func dismissSearch() {
        searchText = ""
        viewModel.updateSearchText("")
        isPresented = false
    }
}
