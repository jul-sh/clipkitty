import AppKit
import Carbon
import ClipKittyShared

// MARK: - HotKey Registration State

private enum RegistrationState: Sendable {
    case unregistered
    case registered(hotKey: EventHotKeyRef, eventHandler: EventHandlerRef)
}

// MARK: - HotKeyManager

/// Manages global hotkey registration using Carbon APIs.
/// @MainActor isolated because Carbon hotkey APIs must be called from the main thread.
@MainActor
public final class HotKeyManager {
    private var state: RegistrationState = .unregistered
    private let callback: @MainActor () -> Void

    public init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    public func register(hotKey: HotKey = .default) {
        // If already registered, just update the hotkey (reuse event handler)
        if case let .registered(oldHotKeyRef, existingEventHandler) = state {
            UnregisterEventHotKey(oldHotKeyRef)

            let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // "CLIP"
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
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // "CLIP"

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

        // Capture callback for use in the C function pointer
        let callback = self.callback

        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
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

    public func unregister() {
        if case let .registered(hotKey, eventHandler) = state {
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(eventHandler)
            state = .unregistered
        }
    }

    deinit {
        // deinit runs on whatever thread deallocates, but Carbon APIs need main thread.
        // Since this class is @MainActor, it should typically be deallocated on main.
        // The state will be cleaned up by the OS when the process exits anyway.
        if case let .registered(hotKey, eventHandler) = state {
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(eventHandler)
        }
    }
}
