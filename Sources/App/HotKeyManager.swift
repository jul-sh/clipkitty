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
        // If already registered, just update the hotkey (reuse event handler)
        if case .registered(let oldHotKeyRef, let existingEventHandler) = state {
            UnregisterEventHotKey(oldHotKeyRef)

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

            if status == noErr, let newHotKeyRef = gMyHotKeyRef {
                state = .registered(hotKey: newHotKeyRef, eventHandler: existingEventHandler)
            } else {
                // Registration failed - remove the orphaned event handler
                RemoveEventHandler(existingEventHandler)
                state = .unregistered
            }
            return
        }

        // First time registration - need to install event handler
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

        var newEventHandler: EventHandlerRef?
        let handlerInstalled = installEventHandler(&newEventHandler)

        if handlerInstalled, let eventHandler = newEventHandler {
            state = .registered(hotKey: newHotKeyRef, eventHandler: eventHandler)
        } else {
            UnregisterEventHotKey(newHotKeyRef)
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
