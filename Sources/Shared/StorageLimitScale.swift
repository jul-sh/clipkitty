import Foundation

/// Logarithmic mapping between a normalized control position in `0...1` and a
/// storage amount in gigabytes. Equal travel corresponds to equal size
/// ratios, so small limits (0.5–2 GB) are as easy to pick as large ones.
public struct StorageLimitScale: Equatable, Sendable {
    public let minGB: Double
    public let maxGB: Double

    public init(minGB: Double = 0.5, maxGB: Double = 64.0) {
        self.minGB = minGB
        self.maxGB = maxGB
    }

    /// Control position in `0...1` for a size in gigabytes (clamped to the range).
    public func position(forGB gb: Double) -> Double {
        let clamped = min(max(gb, minGB), maxGB)
        return log(clamped / minGB) / log(maxGB / minGB)
    }

    /// Size in gigabytes for a control position in `0...1`, rounded so values
    /// read cleanly: whole gigabytes from 1 GB up, tenths below.
    public func gb(forPosition position: Double) -> Double {
        let clamped = min(max(position, 0), 1)
        return rounded(minGB * pow(maxGB / minGB, clamped))
    }

    /// The next clean value in the given direction (+1/-1), for keyboard and
    /// VoiceOver adjustment: 1 GB steps from 1 GB up, 0.1 GB steps below.
    public func adjusting(_ gb: Double, by direction: Int) -> Double {
        let fineStep = gb < 1.0 || (gb == 1.0 && direction < 0)
        return rounded(gb + (fineStep ? 0.1 : 1.0) * Double(direction))
    }

    private func rounded(_ gb: Double) -> Double {
        let rounded = gb >= 1.0 ? gb.rounded() : (gb * 10).rounded() / 10
        return min(max(rounded, minGB), maxGB)
    }
}
