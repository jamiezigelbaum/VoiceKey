import Carbon
import Foundation

enum HotKeyError: Error {
    case registrationFailed(OSStatus)
}

final class HotKeyDispatchTable {
    private var handlers: [UInt32: () -> Void] = [:]

    @discardableResult
    func register(id: UInt32, handler: @escaping () -> Void) -> Bool {
        guard handlers[id] == nil else { return false }
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        handlers[id] = nil
    }

    @discardableResult
    func dispatch(id: UInt32) -> Bool {
        guard let handler = handlers[id] else { return false }
        handler()
        return true
    }
}

private final class CarbonHotKeyDispatcher {
    static let shared = CarbonHotKeyDispatcher()
    static let signature = FourCharCode("VKEY")

    let registrations = HotKeyDispatchTable()
    private var eventHandler: EventHandlerRef?

    private init?() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID(signature: 0, id: 0)
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == CarbonHotKeyDispatcher.signature else {
                return OSStatus(eventNotHandledErr)
            }

            let dispatcher = Unmanaged<CarbonHotKeyDispatcher>.fromOpaque(userData).takeUnretainedValue()
            return dispatcher.registrations.dispatch(id: hotKeyID.id)
                ? noErr
                : OSStatus(eventNotHandledErr)
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return nil }
    }
}

final class GlobalHotKey {
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init?(id: UInt32, configuration: HotKeyConfiguration, handler: @escaping () -> Void) {
        self.id = id

        guard let dispatcher = CarbonHotKeyDispatcher.shared,
              dispatcher.registrations.register(id: id, handler: {
            DispatchQueue.main.async {
                handler()
            }
        }) else {
            return nil
        }

        let hotKeyID = EventHotKeyID(signature: CarbonHotKeyDispatcher.signature, id: id)
        let hotKeyStatus = RegisterEventHotKey(
            configuration.keyCode,
            configuration.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard hotKeyStatus == noErr else {
            dispatcher.registrations.unregister(id: id)
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        CarbonHotKeyDispatcher.shared?.registrations.unregister(id: id)
    }
}

private func FourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
