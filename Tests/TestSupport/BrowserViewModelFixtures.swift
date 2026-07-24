@testable import ClipKittyBrowser
import ClipKittyCore
import ClipKittyRust
import Foundation

@MainActor
func flushMainActor() async {
    for _ in 0 ..< 5 {
        await Task.yield()
    }
}

/// Polls the main actor until `condition` holds or the deadline passes.
/// Fixed-count yield flushing loses the race when the test host's main
/// actor is contended (e.g. SyncEngine startup work), so asserts that
/// depend on async state wait on that state itself.
@MainActor
@discardableResult
func settle(
    timeout: TimeInterval = 2,
    until condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

func makeMatch(id: String, excerpt: String, tags: [ItemTag] = []) -> ItemMatch {
    ItemMatch(
        itemMetadata: ItemMetadata(
            itemId: id,
            icon: .symbol(iconType: .text),
            sourceApp: nil,
            sourceAppBundleId: nil,
            timestampUnix: 0,
            tags: tags
        ),
        presentation: .baseline(excerpt: BaselineExcerpt(text: excerpt))
    )
}

func makeItem(id: String, text: String, tags: [ItemTag] = []) -> ClipboardItem {
    ClipboardItem(
        itemMetadata: ItemMetadata(
            itemId: id,
            icon: .symbol(iconType: .text),
            sourceApp: nil,
            sourceAppBundleId: nil,
            timestampUnix: 0,
            tags: tags
        ),
        content: .text(value: text)
    )
}

extension BrowserSearchResponse {
    init(
        request: SearchRequest,
        items: [ItemMatch],
        firstItem: ClipboardItem?,
        totalCount: Int
    ) {
        self.init(
            request: request,
            items: items,
            firstPreviewPayload: firstItem.map { PreviewPayload(item: $0, decoration: nil) },
            totalCount: totalCount
        )
    }
}
