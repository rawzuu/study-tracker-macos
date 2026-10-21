import Carbon.HIToolbox
import Foundation

/// Klávesové zkratky pro celý systém (fungují i v jiné aplikaci). Carbon `RegisterEventHotKey` nepotřebuje
/// oprávnění Zpřístupnění a funguje i v sandboxu; zkratku dostane jen tahle aplikace.
@MainActor
public final class HotKeyCenter {
    public enum Action: UInt32, CaseIterable, Sendable {
        case toggle = 1
        case show = 2
    }

    private var handler: EventHandlerRef?
    private var registered: [Action: EventHotKeyRef] = [:]
    private let perform: @MainActor (Action) -> Void
    /// Signatura zkratek aplikace („STkb“).
    nonisolated private static let signature: OSType = 0x53_54_6B_62

    public init(perform: @escaping @MainActor (Action) -> Void) {
        self.perform = perform
    }

    /// Zaregistruje zkratky (`nil` = akce bez zkratky). Vrací akce, jejichž zkratku už drží jiná aplikace.
    @discardableResult
    public func set(_ keys: [Action: HotKey?]) -> [Action] {
        installHandler()
        var taken: [Action] = []
        for action in Action.allCases {
            if let ref = registered.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
            guard let key = keys[action] ?? nil else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered[action] = ref } else { taken.append(action) }
        }
        return taken
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyCenter.signature, let action = Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            // Carbon volá na hlavním vlákně (událostní smyčka aplikace).
            MainActor.assumeIsolated { center.perform(action) }
            return noErr
        }, 1, &type, context, &handler)
    }
}
