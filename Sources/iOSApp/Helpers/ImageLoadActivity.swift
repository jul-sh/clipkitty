import Foundation
import Observation

/// Process-wide gauge of in-flight card image work: full-resolution item
/// fetches (`CardImagePreview` / `CardLinkPreview`) and image decodes
/// (`DecodedImageView`).
///
/// Its one consumer is the feed's load-state accessibility identifier
/// (`feed.images.settled` / `feed.images.loading` in `HomeFeedView`), the iOS
/// counterpart of the Mac's `ResultsState_<kind>_<phase>` signal: marketing
/// screenshot captures wait for the settled identifier instead of guessing a
/// sleep long enough for a loaded CI runner — guessed settles (8s, then 15s)
/// each shipped placeholder cards to the App Store; run 28795788433 is the
/// iPad instance, and the iPhone capture regressed the same way after it.
@MainActor
@Observable
final class ImageLoadActivity {
    static let shared = ImageLoadActivity()

    /// True once no image work has been in flight for `settleDelay`.
    ///
    /// The trailing delay closes handoff gaps: a card's fetch task ends one
    /// main-actor hop before the decode task for the fetched bytes begins, so
    /// an instantaneous gauge briefly reads zero mid-pipeline and a capture
    /// polling it could fire between the two stages.
    private(set) var isSettled = true

    @ObservationIgnored private var inFlightCount = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    private static let settleDelay: Duration = .milliseconds(500)

    func begin() {
        inFlightCount += 1
        settleTask?.cancel()
        settleTask = nil
        isSettled = false
    }

    func end() {
        inFlightCount -= 1
        guard inFlightCount == 0 else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.isSettled = true
        }
    }
}
