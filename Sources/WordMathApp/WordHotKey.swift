import AppKit
import Carbon

/// Register only while Word is frontmost so other applications keep their own shortcuts.
final class WordHotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x574D4154, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<WordHotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult func enable(_ enabled: Bool) -> Bool {
        if enabled && registration == nil {
            guard handler != nil else { return false }
            let identifier = EventHotKeyID(signature: 0x574D4154, id: 1)
            return RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | controlKey), identifier,
                                       GetApplicationEventTarget(), 0, &registration) == noErr
        }
        if !enabled, let registration {
            UnregisterEventHotKey(registration)
            self.registration = nil
        }
        return true
    }

    deinit {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
    }
}
