import Carbon
import AppKit

// MARK: - HotKey Registration State

private enum RegistrationState: @unchecked Sendable {
    case unregistered
    case registered(hotKey: EventHotKeyRef, eventHandler: EventHandlerRef)
}

// MARK: - HotKeyManager

/// Manages global hotkey registration using Carbon APIs.
/// @MainActor isolated because Carbon hotkey APIs must be called from the main thread.
@MainActor
final class HotKeyManager {
    private var state: RegistrationState = .unregistered
    private let callback: @MainActor () -> Void

    init(callback: @escaping @MainActor () -> Void) {
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

        // Note: callback is captured via self pointer passed to InstallEventHandler

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard userData != nil else { return OSStatus(eventNotHandledErr) }
            // Carbon callbacks run on main thread, so we can safely call MainActor code
            MainActor.assumeIsolated {
                // Get the callback from the manager
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
                manager.callback()
            }
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
        // deinit runs on whatever thread deallocates, but Carbon APIs need main thread.
        // Since this class is @MainActor, it should typically be deallocated on main.
        // The state will be cleaned up by the OS when the process exits anyway.
        if case .registered(let hotKey, let eventHandler) = state {
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(eventHandler)
        }
    }
}
