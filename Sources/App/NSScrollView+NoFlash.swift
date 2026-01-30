import AppKit

extension NSScrollView {
    private static var hasSwizzled = false

    /// Call once at app launch to globally disable scrollbar flashing.
    static func disableFlashScrollers() {
        guard !hasSwizzled else { return }
        hasSwizzled = true

        let originalSelector = #selector(flashScrollers)
        let swizzledSelector = #selector(swizzled_flashScrollers)

        guard let originalMethod = class_getInstanceMethod(NSScrollView.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSScrollView.self, swizzledSelector)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc private func swizzled_flashScrollers() {
        // No-op: intentionally empty to prevent scrollbar flash on appearance
    }
}
