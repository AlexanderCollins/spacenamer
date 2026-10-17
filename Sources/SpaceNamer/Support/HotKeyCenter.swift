import Carbon.HIToolbox
import SpaceNamerCore

/// Global shortcuts via Carbon's RegisterEventHotKey: no event tap, no Input Monitoring
/// permission, and no CPU cost until a shortcut is pressed.
@MainActor
final class HotKeyCenter {
    private struct Registration {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    nonisolated private static let signature: OSType = 0x53_50_4E_4D // "SPNM"

    private var handler: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1

    init() {
        installHandler()
    }

    /// Returns false when the combination is taken by another app or already registered.
    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        registrations[nextID] = Registration(ref: ref, action: action)
        nextID &+= 1
        return true
    }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func fire(_ id: UInt32) {
        registrations[id]?.action()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard status == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(id.id) }
            return noErr
        }, 1, &eventType, context, &handler)
    }
}
