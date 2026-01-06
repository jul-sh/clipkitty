import Carbon
import AppKit

final class HotKeyManager: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func register() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: 1) // "CLIP"

        var gMyHotKeyRef: EventHotKeyRef?
        let optionKey: UInt32 = UInt32(optionKey)
        let spaceKeyCode: UInt32 = 49

        let status = RegisterEventHotKey(
            spaceKeyCode,
            optionKey,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &gMyHotKeyRef
        )

        if status == noErr {
            hotKeyRef = gMyHotKeyRef
            installEventHandler()
        } else {
            print("Failed to register hotkey: \(status)")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.callback()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}
