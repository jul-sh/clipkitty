import Carbon
import AppKit

private enum RegistrationState {
    case unregistered
    case registered(hotKey: EventHotKeyRef, eventHandler: EventHandlerRef)
}

final class HotKeyManager: @unchecked Sendable {
    private var state: RegistrationState = .unregistered
    private let callback: @Sendable () -> Void

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func register(hotKey: HotKey = .default) {
        // Unregister existing hotkey first
        if case .registered = state {
            unregisterHotKey()
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: 1) // "CLIP"

        var gMyHotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &gMyHotKeyRef
        )

        guard status == noErr, let newHotKeyRef = gMyHotKeyRef else {
            return
        }

        // Install event handler and atomically create registered state
        var newEventHandler: EventHandlerRef?
        let handlerInstalled = installEventHandler(&newEventHandler)

        if handlerInstalled, let eventHandler = newEventHandler {
            state = .registered(hotKey: newHotKeyRef, eventHandler: eventHandler)
        } else {
            // Partial registration failure - clean up the hot key
            UnregisterEventHotKey(newHotKeyRef)
        }
    }

    private func unregisterHotKey() {
        if case .registered(let hotKey, _) = state {
            UnregisterEventHotKey(hotKey)
            state = .unregistered
        }
    }

    private func installEventHandler(_ eventHandler: inout EventHandlerRef?) -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.callback()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        return status == noErr
    }

    func unregister() {
        if case .registered(let hotKey, let eventHandler) = state {
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(eventHandler)
            state = .unregistered
        }
    }

    deinit {
        unregister()
    }
}
