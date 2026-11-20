import SwiftUI

struct MacDraftEditor: UIViewRepresentable {
    @ObservedObject var client: LinkedClient

    final class Coordinator: NSObject, UITextViewDelegate {
        let client: LinkedClient
        init(_ client: LinkedClient) { self.client = client }
        func textViewDidChange(_ view: UITextView) { client.draft = view.text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(client) }

    func makeUIView(context: Context) -> UITextView {
        let view = client.richEditor
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = String(localized: "Text for Mac")
        DispatchQueue.main.async { [weak view, weak client] in
            if client?.editing == true, view?.window != nil { view?.becomeFirstResponder() }
        }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = client.submitting == nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(108, max(39, height)))
    }

    static func attributed(_ text: String, styles: [LinkedMessage.StyleRun]) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let rich = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
        for run in styles where run.start >= 0 && run.start <= rich.length && run.count > 0 && run.count <= rich.length - run.start {
            let range = NSRange(location: run.start, length: run.count)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.style & 1 != 0 { traits.insert(.traitBold) }
            if run.style & 2 != 0 { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                rich.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
            if run.style & 4 != 0 { rich.addAttribute(.underlineStyle, value: 1, range: range) }
        }
        return rich
    }

    static func mask(_ attributes: [NSAttributedString.Key: Any]) -> Int {
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        let underline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0
        return (traits.contains(.traitBold) ? 1 : 0) | (traits.contains(.traitItalic) ? 2 : 0) | (underline != 0 ? 4 : 0)
    }

    static func styles(in text: NSAttributedString?) -> [LinkedMessage.StyleRun] {
        guard let text else { return [] }
        var runs: [LinkedMessage.StyleRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let style = mask(attrs)
            if style != 0 { runs.append(.init(start: range.location, count: range.length, style: style)) }
        }
        return runs
    }
}
