import AppKit
import Carbon

/// Never reads the current value or selection text. Commits address a specific editable element.
final class LinkedFocus {
    private var element: AXUIElement?
    private(set) var token: UUID?

    func refresh() {
        let current = editableElement()
        if let element, let current, CFEqual(element, current) { return }
        element = current
        token = current.map { _ in UUID() }
    }

    func insert(_ text: String, token expected: UUID?) -> Bool {
        refresh()
        guard let expected, expected == token, let element, !text.isEmpty,
              text.utf8.count <= 16384 else { return false }
        // A writable AXSelectedText can report success in a custom editor without
        // invoking its normal typing handlers. Send single-line text through those handlers.
        if !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            var pid: pid_t = 0
            guard CGPreflightPostEventAccess(), AXUIElementGetPid(element, &pid) == .success,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            let source = CGEventSource(stateID: .privateState)
            var units: [UniChar] = []
            func post() -> Bool {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
                for event in [down, up] {
                    event.flags = []
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.postToPid(pid)
                }
                units.removeAll(keepingCapacity: true)
                return true
            }
            for scalar in text.unicodeScalars {
                let encoded = scalar.utf16
                if units.count + encoded.count > 16, !post() { return false }
                units.append(contentsOf: encoded)
            }
            return post()
        }
        // Insert newlines as selection text so Return cannot submit a chat or form.
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func editableElement() -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let owner = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(owner, 0.12)
        func value(_ object: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(object, attribute as CFString, &result) == .success ? result : nil
        }
        guard let raw = value(owner, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let field = raw as! AXUIElement
        guard let role = value(field, kAXRoleAttribute) as? String, [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        func writable(_ attribute: String) -> Bool {
            var result = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(field, attribute as CFString, &result) == .success && result.boolValue
        }
        guard writable(kAXSelectedTextAttribute) || writable(kAXValueAttribute) else { return nil }
        return field
    }
}
