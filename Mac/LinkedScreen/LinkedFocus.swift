import AppKit
import Carbon

/// Reads selected text only for an explicit selection-edit transaction.
final class LinkedFocus {
    private var element: AXUIElement?
    private let pollingQueue = DispatchQueue(label: "AirPointer.LinkedFocus", qos: .userInitiated)
    private var polling = false
    private var revision = 0
    private(set) var token: UUID?

    func invalidate() {
        revision += 1
        snapshot = nil
        element = nil
        token = nil
    }

    func refresh() {
        revision += 1
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        setEditableElement(pid.flatMap(Self.editableElement))
    }

    func refreshInBackground(completion: @escaping () -> Void) {
        guard !polling else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            setEditableElement(nil)
            completion()
            return
        }
        polling = true
        let requestedRevision = revision
        pollingQueue.async { [weak self] in
            let current = Self.editableElement(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.polling = false
                guard self.revision == requestedRevision,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.setEditableElement(IsSecureEventInputEnabled() ? nil : current)
                completion()
            }
        }
    }

    private func setEditableElement(_ current: AXUIElement?) {
        if let element, let current, CFEqual(element, current) { return }
        snapshot = nil
        element = current
        token = current.map { _ in UUID() }
    }

    func matchesClick(at point: CGPoint) -> Bool {
        guard let element, !IsSecureEventInputEnabled() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return false }
        // Web editors may return a child text element for the hit.
        for _ in 0..<8 {
            guard let current = hit else { return false }
            if CFEqual(current, element) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            hit = (parent as! AXUIElement)
        }
        return false
    }

    private var snapshot: (id: UUID, range: CFRange, text: String)?

    private func selection(in element: AXUIElement) -> (CFRange, String)? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length > 0, range.length <= 16384 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty, text.utf8.count <= 16384 else { return nil }
        return (range, text)
    }

    func readSelection(token expected: UUID?) -> (id: UUID, text: String, styles: [LinkedMessage.StyleRun])? {
        refresh()
        guard let expected, expected == token, let element, let (range, text) = selection(in: element) else { return nil }
        let id = UUID()
        snapshot = (id, range, text)
        var selectedRange = range
        var attributes: CFTypeRef?
        var styles: [LinkedMessage.StyleRun] = []
        if let parameter = AXValueCreate(.cfRange, &selectedRange),
           AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                parameter, &attributes) == .success, let rich = attributes as? NSAttributedString,
           rich.string.utf8.elementsEqual(text.utf8) {
            rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, range, _ in
                var style = 0
                if let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { style |= 1 }
                    if traits.contains(.italic) { style |= 2 }
                }
                if (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { style |= 4 }
                if style != 0 { styles.append(.init(start: range.location, count: range.length, style: style)) }
            }
        }
        return (id, text, styles.count <= 512 ? styles : [])
    }

    func commit(_ text: String, message: LinkedMessage) -> Bool {
        refresh()
        guard let expected = message.token, expected == token, let element, text.utf8.count <= 16384 else { return false }
        if let id = message.selection {
            guard let saved = snapshot, saved.id == id, let (range, current) = selection(in: element),
                  range.location == saved.range.location, range.length == saved.range.length,
                  current.utf8.elementsEqual(saved.text.utf8) else { return false }
            if text.isEmpty {
                let ok = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "" as CFString) == .success
                if ok { snapshot = nil }
                return ok
            }
        }
        let success: Bool
        if let styles = message.styles, !styles.isEmpty {
            success = pasteFormatted(text, styles: styles, into: element)
        } else { success = insert(text, token: expected) }
        if success { snapshot = nil }
        return success
    }

    private func pasteFormatted(_ text: String, styles: [LinkedMessage.StyleRun], into element: AXUIElement) -> Bool {
        guard !text.isEmpty, styles.count <= 512 else { return false }
        let font = NSFont.systemFont(ofSize: 14)
        let rich = NSMutableAttributedString(string: text, attributes: [.font: font])
        var end = 0
        for run in styles {
            guard run.start >= end, run.start <= rich.length, run.count > 0,
                  run.count <= rich.length - run.start, (1...7).contains(run.style) else { return false }
            let range = NSRange(location: run.start, length: run.count)
            var traits: NSFontTraitMask = []
            if run.style & 1 != 0 { traits.insert(.boldFontMask) }
            if run.style & 2 != 0 { traits.insert(.italicFontMask) }
            rich.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traits), range: range)
            if run.style & 4 != 0 { rich.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            end = NSMaxRange(range)
        }
        let all = NSRange(location: 0, length: rich.length)
        var pid: pid_t = 0
        guard let rtf = rich.rtf(from: all, documentAttributes: [:]),
              !IsSecureEventInputEnabled(), AXUIElementGetPid(element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        let item = NSPasteboardItem()
        item.setData(rtf, forType: .rtf)
        item.setString(text, forType: .string)
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([item]) else { return false }
        for event in [down, up] { event.flags = .maskCommand; event.postToPid(pid) }
        return true
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

    private static func editableElement(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let owner = AXUIElementCreateApplication(pid)
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
