import SwiftUI
import UIKit
import WebKit

struct DesktopWorkspace: View {
    let connection: PhoneConnection
    @Environment(\.scenePhase) private var scenePhase
    let computer: DesktopComputer
    @ObservedObject var session: DesktopSession
    let disconnect: () -> Void

    private enum Panel { case controls, display, quality, tools, shortcuts, modifiers, arrows, info }
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var immersive = false
    private var split: Bool { verticalSize != .compact && !immersive }
    private var desktopAspect: CGFloat {
        let sides = session.resolution.components(separatedBy: " × ").compactMap(Double.init)
        return sides.count == 2 && sides[1] > 0 ? sides[0] / sides[1] : 1.6
    }
    @State private var panel: Panel?
    @State private var keyboard = false
    @State private var draft = ""
    @State private var collapsed = true
    @State private var observing = false
    @State private var dragObjects = false
    @State private var statistics = false
    @State private var shareImage: UIImage?
    @State private var screenshotError = false
    @State private var modifiers: Set<Int> = []
    @FocusState private var composing: Bool
    @AppStorage("screenSharing.layout") private var scale = "fit"
    @AppStorage("screenSharing.quality") private var quality = 6

    private let cyan = Color(red: 0.47, green: 0.89, blue: 0.94)
    private let control = 0xffe3
    private let command = 0xffeb
    private let option = 0xffe9

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    if split {
                        HStack {
                            Label(computer.name, systemImage: "desktopcomputer").lineLimit(1)
                            Spacer()
                            Button("Disconnect", role: .destructive, action: disconnect)
                        }.font(.subheadline.bold()).padding(.horizontal).frame(height: 44)
                    }
                    if let web = session.web {
                        DesktopCanvas(web: web)
                            .allowsHitTesting(false)
                            .overlay { MirrorTouchSurface(session: session, dragObjects: dragObjects) }
                            .frame(height: split ? min(geometry.size.width / desktopAspect, geometry.size.height * (keyboard ? 0.65 : 0.55)) : nil)
                    }
                    if split {
                        HStack {
                            dockButton("ellipsis.circle", "Session Settings") { toggle(.controls) }
                            Spacer()
                            dockButton("arrow.up.left.and.arrow.down.right", "Full Screen") { immersive = true }
                            dockButton("keyboard", "Keyboard", active: keyboard) { toggleKeyboard() }.disabled(observing)
                        }.padding(.horizontal)
                        if keyboard { composer; Spacer(minLength: 0) }
                        else { padView.disabled(observing) }
                    }
                }
                .ignoresSafeArea(.container, edges: split ? [] : .all)

                if panel != nil {
                    Color.black.opacity(0.32).ignoresSafeArea()
                        .onTapGesture { panel = nil }
                        .accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    if let panel {
                        panelView(panel, maxHeight: max(100, geometry.size.height * 0.57))
                    }
                    if !split {
                        if keyboard { composer }
                        dock
                    }
                }
                .frame(maxWidth: 470)
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }
            .overlay(alignment: .topTrailing) {
                if session.canResetViewport && panel == nil && !collapsed {
                    Button(action: restoreOverview) {
                        Label("Overview", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                if statistics {
                    Label(session.resolution.isEmpty ? "VNC" : "VNC · " + session.resolution, systemImage: "waveform")
                        .font(.caption.monospacedDigit()).padding(9).background(.regularMaterial, in: Capsule())
                        .padding(12).allowsHitTesting(false)
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            configure()
            session.onMirrorClick = { point, token in
                guard !observing, scenePhase == .active, connection.connected,
                      connection.accessibility, !connection.macPaused,
                      connection.mirrorHosts.contains(where: {
                          $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).caseInsensitiveCompare(
                              computer.host.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == .orderedSame
                      }) else { return }
                connection.send(.init(.mirrorFocus, x: point.x, y: point.y, time: token))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    if session.focusRequest == token { session.cancelFocusRequest() }
                }
            }
        }
        .onDisappear { session.cancelFocusRequest(); session.onMirrorClick = nil }
        .onChange(of: scenePhase) { _, _ in session.cancelFocusRequest() }
        .onChange(of: panel) { _, _ in session.cancelFocusRequest() }
        .onReceive(connection.editableMirrorClick) { token in
            guard session.focusRequest == token, session.connected, connection.connected,
                  scenePhase == .active, !observing, panel == nil else { return }
            toggleKeyboard(forceOpen: true)
        }
        .onChange(of: observing) { _, value in
            if value { keyboard = false; composing = false; modifiers.removeAll() }
            configure()
        }
        .onChange(of: split) { _, _ in configure() }
        .onChange(of: scale) { _, _ in configure() }
        .onChange(of: quality) { _, _ in configure() }
        .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
            if let shareImage { DesktopImageShare(image: shareImage) }
        }
        .alert("Couldn’t Capture Screen", isPresented: $screenshotError) { Button("OK", role: .cancel) {} }
    }

    private var padView: some View {
        VStack(spacing: 6) {
            MirrorPad(session: session)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay { Text("单指移动指针 · 双指滚动").font(.caption).foregroundStyle(.secondary).allowsHitTesting(false) }
            HStack {
                mouseButton("左键", 1)
                mouseButton("右键", 4)
            }
        }.padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func mouseButton(_ title: String, _ mask: Int) -> some View {
        MirrorMouseButton(session: session, title: title, mask: mask)
            .frame(maxWidth: .infinity).frame(height: 44)
    }

    private var dock: some View {
        HStack(spacing: 3) {
            dockButton(collapsed ? "rectangle.expand.vertical" : "chevron.down", "Toggle Controls") {
                collapsed.toggle()
                panel = nil
                keyboard = false
                composing = false
            }
            if immersive { dockButton("rectangle.split.1x2", "Trackpad") { immersive = false } }
            if !collapsed {
                dockButton("keyboard", "Keyboard", active: keyboard) { toggleKeyboard() }
                    .disabled(observing)
                dockButton("command", "Modifier Keys", active: panel == .modifiers) { toggle(.modifiers) }
                    .disabled(observing)
                dockButton("escape", "Escape") { key(0xff1b) }.disabled(observing)
                dockButton("arrow.up.and.down.and.arrow.left.and.right", "Direction Keys", active: panel == .arrows) { toggle(.arrows) }
                    .disabled(observing)
                dockButton("square.grid.2x2", "Shortcuts", active: panel == .shortcuts) { toggle(.shortcuts) }
                    .disabled(observing)
                dockButton("slider.horizontal.3", "Session Settings", active: panel == .controls) { toggle(.controls) }
            }
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dockButton(_ icon: String, _ name: LocalizedStringKey, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 41, height: 44)
                .foregroundStyle(active ? cyan : .primary)
                .background(active ? cyan.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).accessibilityLabel(Text(name))
    }

    private var composer: some View {
        HStack {
            TextField("Type on Mac", text: $draft)
                .focused($composing).onAppear { composing = true }.submitLabel(.send).onSubmit(sendDraft)
            Button("Send", action: sendDraft).disabled(draft.isEmpty)
            Button { key(0xff08) } label: { Image(systemName: "delete.left") }.accessibilityLabel("Backspace")
            Button { key(0xff0d) } label: { Image(systemName: "return") }.accessibilityLabel("Return")
        }
        .padding(.horizontal, 12).frame(minHeight: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func panelView(_ active: Panel, maxHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            panelContent(active)
            ScrollView { panelContent(active) }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.14)))
    }

    @ViewBuilder private func panelContent(_ active: Panel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if active != .controls {
                    Button { panel = .controls } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                        .accessibilityLabel("Session Settings")
                }
                Text(title(active)).font(.headline)
                Spacer()
                Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                    .accessibilityLabel("Close")
            }.buttonStyle(.plain)
            switch active {
            case .controls:
                setting("Display", icon: "aspectratio", next: .display)
                setting("Picture Quality", icon: "photo", next: .quality)
                setting("Tools", icon: "wrench.and.screwdriver", next: .tools)
                setting("Shortcuts", icon: "command", next: .shortcuts)
                if !observing {
                    setting("Modifier Keys", icon: "option", next: .modifiers)
                    setting("Direction Keys", icon: "arrow.left.and.right", next: .arrows)
                }
                Divider()
                Button("Disconnect", systemImage: "power", role: .destructive, action: disconnect)
                    .frame(minHeight: 42)
            case .display:
                choice("Fit Entire Screen", value: "fit", current: $scale)
                choice("Fill Screen", value: "fill", current: $scale)
                choice("Original Size", value: "actual", current: $scale)
                Text("Pinch to zoom. Drag with two fingers to move the enlarged view.")
                    .font(.footnote).foregroundStyle(.secondary)
                Divider()
                Toggle("拖动窗口或文件", isOn: $dragObjects).disabled(observing)
                Toggle("Observe Only", isOn: $observing)
            case .quality:
                choice("Data Saver", value: 3, current: $quality)
                choice("Balanced", value: 6, current: $quality)
                choice("Detail", value: 9, current: $quality)
            case .tools:
                Button("Send Text", systemImage: "text.cursor") { panel = nil; toggleKeyboard(forceOpen: true) }
                    .disabled(observing)
                if !observing {
                    PasteButton(payloadType: String.self) { values in
                        if let text = values.first { session.sendClipboard(text) }
                    }.labelStyle(.titleAndIcon)
                }
                Button("Capture and Share", systemImage: "camera") {
                    panel = nil
                    Task {
                        if let bytes = await session.screenshot(), let image = UIImage(data: bytes) { shareImage = image }
                        else { screenshotError = true }
                    }
                }
                Toggle("Display Information Overlay", isOn: $statistics)
                setting("Connection Information", icon: "info.circle", next: .info)
            case .info:
                LabeledContent("Mac", value: computer.name)
                LabeledContent("Connection", value: "VNC")
                if !session.resolution.isEmpty { LabeledContent("Desktop Size", value: session.resolution) }
            case .shortcuts:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2)) {
                    shortcut("Mission Control", 0xff52, [control])
                    shortcut("App Windows", 0xff54, [control])
                    shortcut("Show Desktop", 0xffc8)
                    shortcut("Spotlight", 32, [command])
                    shortcut("Switch App", 0xff09, [command])
                    shortcut("Lock Screen", 113, [control, command])
                    shortcut("Previous Space", 0xff51, [control])
                    shortcut("Next Space", 0xff53, [control])
                    shortcut("Minimize", 109, [command])
                    shortcut("Close Window", 119, [command])
                    shortcut("Force Quit", 0xff1b, [option, command])
                    shortcut("Hide App", 104, [command])
                }.disabled(observing)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(1...12, id: \.self) { index in
                        tile(Text("F\(index)")) { key(0xffbd + index) }
                    }
                }.disabled(observing)
            case .modifiers:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    modifier("⌘", command, label: "Command")
                    modifier("⌥", option, label: "Option")
                    modifier("⌃", control, label: "Control")
                    modifier("⇧", 0xffe1, label: "Shift")
                }
                Text("Selected modifiers apply to the next key.").font(.footnote).foregroundStyle(.secondary)
                shortcut("Tab", 0xff09)
            case .arrows:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    shortcut("←", 0xff51)
                    shortcut("↑", 0xff52)
                    shortcut("↓", 0xff54)
                    shortcut("→", 0xff53)
                    shortcut("Home", 0xff50)
                    shortcut("End", 0xff57)
                    shortcut("Page Up", 0xff55)
                    shortcut("Page Down", 0xff56)
                }
            }
        }
    }

    private func title(_ panel: Panel) -> LocalizedStringKey {
        switch panel {
        case .controls: "Session Settings"
        case .display: "Display"
        case .quality: "Picture Quality"
        case .tools: "Tools"
        case .info: "Connection Information"
        case .shortcuts: "Shortcuts"
        case .arrows: "Direction Keys"
        case .modifiers: "Modifier Keys"
        }
    }

    private func setting(_ title: LocalizedStringKey, icon: String, next: Panel) -> some View {
        Button { panel = next } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }.frame(minHeight: 34).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func choice<Value: Equatable>(_ title: LocalizedStringKey, value: Value, current: Binding<Value>) -> some View {
        Button { current.wrappedValue = value } label: {
            HStack {
                Text(title)
                Spacer()
                if current.wrappedValue == value { Image(systemName: "checkmark").foregroundStyle(cyan) }
            }.frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(current.wrappedValue == value ? .isSelected : [])
    }

    private func tile(_ title: Text, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title.font(.footnote.weight(.medium)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected ? cyan.opacity(0.24) : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func modifier(_ symbol: String, _ code: Int, label: LocalizedStringKey) -> some View {
        tile(Text(symbol), selected: modifiers.contains(code)) {
            if !modifiers.insert(code).inserted { modifiers.remove(code) }
        }.accessibilityLabel(Text(label)).accessibilityAddTraits(modifiers.contains(code) ? .isSelected : [])
    }

    private func shortcut(_ title: LocalizedStringKey, _ code: Int, _ held: [Int] = []) -> some View {
        tile(Text(title)) { key(code, held) }
    }

    private func key(_ code: Int, _ held: [Int] = []) {
        guard !observing else { return }
        session.send(key: code, modifiers: modifiers.union(held).sorted())
        modifiers.removeAll()
    }

    private func toggle(_ target: Panel) { panel = panel == target ? nil : target }

    private func toggleKeyboard(forceOpen: Bool = false) {
        session.cancelFocusRequest()
        keyboard = forceOpen || !keyboard
        composing = keyboard
    }

    private func sendDraft() {
        guard !draft.isEmpty, !observing else { return }
        session.send(text: draft)
        draft = ""
    }

    private func restoreOverview() {
        scale = "fit"
        session.resetViewport()
    }

    private func configure() {
        session.configure(scale: scale, observing: observing, quality: quality)
    }
}

private struct DesktopCanvas: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// A stationary remote image with displacement and deceleration supplied by UIKit.
private class MirrorScrollingView: UIScrollView, UIScrollViewDelegate {
    let session: DesktopSession
    let atPointer: Bool
    private var lastOffset: CGPoint?
    private var wheel = MirrorWheelMotion(spacing: 14)
    private let origin = CGPoint(x: 65536, y: 65536)

    init(session: DesktopSession, atPointer: Bool) {
        self.session = session
        self.atPointer = atPointer
        super.init(frame: .zero)
        delegate = self
        bounces = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        isDirectionalLockEnabled = true
        panGestureRecognizer.minimumNumberOfTouches = atPointer ? 2 : 1
        panGestureRecognizer.maximumNumberOfTouches = atPointer ? 2 : 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: 2 * origin.x + bounds.width, height: 2 * origin.y + bounds.height)
        if size != contentSize {
            finishScrolling()
            contentSize = size
            setContentOffset(origin, animated: false)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        finishScrolling()
        let point = panGestureRecognizer.location(in: self)
        let delta = panGestureRecognizer.translation(in: self)
        if !atPointer {
            session.startScroll(CGPoint(x: (point.x - bounds.minX - delta.x) / max(1, bounds.width),
                                        y: (point.y - bounds.minY - delta.y) / max(1, bounds.height)))
        }
        let desktopWidth = Double(session.resolution.components(separatedBy: " × ").first ?? "") ?? bounds.width
        let gain = min(3, max(1, desktopWidth / max(1, bounds.width)))
        wheel = MirrorWheelMotion(spacing: (atPointer ? 18 : 14) / gain)
        lastOffset = contentOffset
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let previous = lastOffset else { return }
        lastOffset = contentOffset
        let delta = CGPoint(x: previous.x - contentOffset.x, y: previous.y - contentOffset.y)
        session.scroll(wheel.ticks(for: delta), atPointer: atPointer)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resetOffset() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { resetOffset() }

    private func resetOffset() {
        finishScrolling()
        setContentOffset(origin, animated: false)
    }
    func finishScrolling() {
        guard lastOffset != nil else { return }
        lastOffset = nil
        if !atPointer { session.endScroll() }
    }
}

private struct MirrorTouchSurface: UIViewRepresentable {
    let session: DesktopSession
    let dragObjects: Bool

    func makeUIView(context: Context) -> Surface { Surface(session: session) }
    func updateUIView(_ view: Surface, context: Context) { view.dragObjects = dragObjects }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.finish() }

    final class Surface: MirrorScrollingView, UIGestureRecognizerDelegate {
        var dragObjects = false {
            didSet { panGestureRecognizer.isEnabled = !dragObjects }
        }
        private var draggingObject = false

        init(session: DesktopSession) {
            super.init(session: session, atPointer: false)
            isMultipleTouchEnabled = true
            let slide = UIPanGestureRecognizer(target: self, action: #selector(slide(_:)))
            slide.maximumNumberOfTouches = 1
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
            tap.require(toFail: panGestureRecognizer)
            tap.require(toFail: slide)
            tap.require(toFail: hold)
            for gesture in [slide, tap, hold] { addGestureRecognizer(gesture) }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(moveViewport(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
            for gesture in [pan, pinch] {
                gesture.delegate = self
                addGestureRecognizer(gesture)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            if let slide = gesture as? UIPanGestureRecognizer, slide !== panGestureRecognizer, slide.minimumNumberOfTouches == 1 { return dragObjects }
            if gesture is UILongPressGestureRecognizer { return !dragObjects }
            return super.gestureRecognizerShouldBegin(gesture)
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            session.touch("click", at: normalize(gesture.location(in: self)))
        }

        @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began && !dragObjects {
                session.touch("right", at: normalize(gesture.location(in: self)))
            }
        }

        @objc private func slide(_ pan: UIPanGestureRecognizer) {
            let point = pan.location(in: self), delta = pan.translation(in: self)
            if pan.state == .began {
                draggingObject = true
                let start = normalize(CGPoint(x: point.x - delta.x, y: point.y - delta.y))
                session.touch("down", at: start)
            }
            guard draggingObject else { return }
            switch pan.state {
            case .began, .changed, .ended:
                session.touch("move", at: normalize(point))
                pan.setTranslation(.zero, in: self)
                if pan.state == .ended { finish() }
            default: finish()
            }
        }

        func finish() {
            finishScrolling()
            guard draggingObject else { return }
            draggingObject = false
            session.endScroll()
        }

        private func normalize(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - bounds.minX) / max(1, bounds.width), y: (p.y - bounds.minY) / max(1, bounds.height))
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gesture is UIPinchGestureRecognizer && (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2) ||
            (other is UIPinchGestureRecognizer && (gesture as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2)
        }

        @objc private func moveViewport(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .began || pan.state == .changed else { return }
            finish()
            let point = pan.location(in: self), delta = pan.translation(in: self)
            session.adjustViewport(from: normalize(CGPoint(x: point.x - delta.x, y: point.y - delta.y)),
                                   to: normalize(point), scale: 1)
            pan.setTranslation(.zero, in: self)
        }

        @objc private func zoom(_ pinch: UIPinchGestureRecognizer) {
            guard pinch.state == .began || pinch.state == .changed else { return }
            finish()
            let point = normalize(pinch.location(in: self))
            session.adjustViewport(from: point, to: point, scale: pinch.scale)
            pinch.scale = 1
        }
    }
}

private struct DesktopImageShare: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct MirrorPad: UIViewRepresentable {
    let session: DesktopSession
    func makeCoordinator() -> Handler { Handler(session) }
    func makeUIView(context: Context) -> UIView {
        let view = MirrorScrollingView(session: session, atPointer: true)
        view.isMultipleTouchEnabled = true
        let handler = context.coordinator
        let move = UIPanGestureRecognizer(target: handler, action: #selector(Handler.pan(_:)))
        move.maximumNumberOfTouches = 1
        view.addGestureRecognizer(move)
        for count in 1...2 {
            let tap = UITapGestureRecognizer(target: handler, action: #selector(Handler.tap(_:)))
            tap.numberOfTouchesRequired = count
            tap.require(toFail: count == 1 ? move : view.panGestureRecognizer)
            view.addGestureRecognizer(tap)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    @MainActor final class Handler: NSObject {
        let session: DesktopSession
        init(_ session: DesktopSession) { self.session = session }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            session.pad("pulse", gesture.numberOfTouchesRequired == 2 ? 4 : 1)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            session.pad("move", delta.x, delta.y)
        }
    }
}

private struct MirrorMouseButton: UIViewRepresentable {
    let session: DesktopSession
    let title: String
    let mask: Int
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(configuration: .gray())
        button.setTitle(title, for: .normal)
        button.addAction(UIAction { _ in session.pad("press", CGFloat(mask)) }, for: .touchDown)
        button.addAction(UIAction { _ in session.pad("release", CGFloat(mask)) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {}
    static func dismantleUIView(_ button: UIButton, coordinator: ()) {
        button.sendActions(for: .touchCancel)
    }
}
