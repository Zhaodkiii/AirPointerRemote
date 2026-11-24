import Network
import SwiftUI
import WebKit

/// UIKit has already recognized a pan before this accumulator receives motion.
struct MirrorWheelMotion {
    let spacing: CGFloat
    private var remainder = CGPoint.zero
    private var started = false

    init(spacing: CGFloat) { self.spacing = spacing }

    mutating func ticks(for delta: CGPoint) -> CGPoint {
        guard delta != .zero else { return .zero }
        remainder.x += delta.x
        remainder.y += delta.y
        var ticks = CGPoint(x: (remainder.x / spacing).rounded(.towardZero),
                            y: (remainder.y / spacing).rounded(.towardZero))
        remainder.x -= ticks.x * spacing
        remainder.y -= ticks.y * spacing
        if !started && ticks == .zero {
            if abs(delta.y) >= abs(delta.x) {
                ticks.y = delta.y > 0 ? 1 : -1
                remainder.y = 0
            } else {
                ticks.x = delta.x > 0 ? 1 : -1
                remainder.x = 0
            }
        }
        started = true
        return ticks
    }
}

@MainActor
final class DesktopSession: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var connected = false
    @Published private(set) var status = "正在连接…"
    let mirrorVideo = MirrorVideo()
    #if os(iOS)
    let pictureInPicture = DesktopPictureInPicture()
    #endif
    @Published private(set) var resolution = ""
    @Published private(set) var canResetViewport = false
    @Published private(set) var authenticationRejected = false
    @Published private(set) var web: WKWebView?
    var onMirrorClick: ((CGPoint, Double) -> Void)?
    private(set) var focusRequest = 0.0
    func cancelFocusRequest() { focusRequest = 0 }

    private var transport: NWConnection?
    private var timeout: Task<Void, Never>?
    private var credentials: [String: String] = [:]
    private var authenticated: (() -> Void)?

    func start(_ computer: DesktopComputer, username: String, password: String, account: Bool,
               onConnected: @escaping () -> Void) {
        stop()
        authenticationRejected = false
        guard let page = Bundle.main.url(forResource: "SystemDesktop", withExtension: "html") else {
            status = "缺少桌面组件，请重新安装 App。"; return
        }
        credentials = ["username": username, "password": password, "method": account ? "account" : "vnc"]
        authenticated = onConnected
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "desktop")
        let view = WKWebView(frame: .zero, configuration: config)
        web = view
        view.navigationDelegate = self
        transport = NWConnection(to: computer.endpoint, using: .tcp)
        status = "正在连接 " + computer.name
        view.loadFileURL(page, allowingReadAccessTo: page)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { self?.fail("连接超时。请确认电脑已唤醒、屏幕共享已开启，并允许本地网络访问。") }
        }
    }

    private func openTransport(_ webView: WKWebView) {
        guard webView === web, let connection = transport else { return }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.transport === connection else { return }
                switch state {
                case .ready:
                    let args = self.credentials
                    self.credentials.removeAll()
                    webView.callAsyncJavaScript("begin(username,password,method)", arguments: args, in: nil, in: .page) { result in
                        guard self.transport === connection else { return }
                        if case .failure = result { self.fail("桌面组件启动失败。"); return }
                        self.receive(connection)
                    }
                case .failed(let error): self.fail("连接失败：" + error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            DispatchQueue.main.async {
                guard let self, self.transport === connection else { return }
                guard let data, !data.isEmpty else { self.fail("Mac 已断开连接。"); return }
                self.web?.callAsyncJavaScript("receive(packet)", arguments: ["packet": data.base64EncodedString()], in: nil, in: .page) { result in
                    guard self.transport === connection else { return }
                    if case .failure = result { self.fail("无法读取远程画面。"); return }
                    if complete || error != nil { self.fail("Mac 已断开连接。"); return }
                    self.receive(connection)
                }
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === web, let connection = transport,
              let body = message.body as? [String: String] else { return }
        switch body["kind"] {
        case "ready": if let web { openTransport(web) }
        case "send":
            guard let value = body["value"], let data = Data(base64Encoded: value) else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async {
                    if self?.transport === connection { self?.fail(error.localizedDescription) }
                }
            })
        case "connected":
            timeout?.cancel(); connected = true; status = "已连接"
            authenticated?(); authenticated = nil
        case "mirrorFrame":
            if let value = body["value"], let jpeg = Data(base64Encoded: value) { mirrorVideo.receive(jpeg) }
        case "resolution": resolution = body["value"] ?? ""
        case "overview": canResetViewport = body["value"] == "yes"
        case "authError":
            authenticationRejected = true
            fail("登录失败，请检查凭据及 Mac 允许访问的用户。")
        case "close", "ended": fail(connected ? "会话已结束。" : "无法完成登录，请检查认证方式和屏幕共享设置。")
        default: break
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === web { fail("桌面显示进程已退出，请重新连接。") }
    }

    func send(text: String) {
        run("typeText(text)", ["text": text])
    }

    func send(key: Int, modifiers: [Int] = []) {
        run("specialKey(key, modifiers)", ["key": key, "modifiers": modifiers])
    }

    func configure(scale: String, observing: Bool, quality: Int, adaptive: Bool = false) {
        run("configure(scale, observing, quality, adaptive)", [
            "scale": scale, "observing": observing, "quality": quality, "adaptive": adaptive
        ])
    }

    func pad(_ action: String, _ a: CGFloat, _ b: CGFloat = 0) {
        pointerInput("padInput(action,a,b)", ["action": action, "a": a, "b": b],
                     checkFocus: (action == "pulse" || action == "release") && a == 1)
    }

    func touch(_ action: String, at point: CGPoint) {
        pointerInput("directTouch(action,u,v)", ["action": action, "u": point.x, "v": point.y],
                     checkFocus: action == "click")
    }

    private func pointerInput(_ script: String, _ arguments: [String: Any], checkFocus: Bool) {
        cancelFocusRequest()
        guard checkFocus, onMirrorClick != nil, connected, let web else { run(script, arguments); return }
        let token = Double(Int.random(in: 1..<(1 << 48)))
        focusRequest = token
        web.callAsyncJavaScript("return " + script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard let self, self.connected, self.focusRequest == token,
                  case .success(let value) = result, let pair = value as? [Double], pair.count == 2 else { return }
            self.onMirrorClick?(CGPoint(x: pair[0], y: pair[1]), token)
        }
    }

    func startScroll(_ point: CGPoint) {
        cancelFocusRequest()
        run("startScroll(u,v)", ["u": point.x, "v": point.y])
    }

    func scroll(_ ticks: CGPoint, atPointer: Bool = false) {
        cancelFocusRequest()
        guard ticks != .zero else { return }
        run("scrollTicks(dx,dy,atPointer)", ["dx": ticks.x, "dy": ticks.y, "atPointer": atPointer])
    }

    func endScroll() { run("endScroll()", [:]) }

    func adjustViewport(from: CGPoint, to: CGPoint, scale: CGFloat) {
        cancelFocusRequest()
        run("adjustViewport(u,v,nextU,nextV,ratio)", ["u": from.x, "v": from.y,
            "nextU": to.x, "nextV": to.y, "ratio": scale])
    }

    func resetViewport() {
        run("resetViewport()", [:])
    }

    func sendClipboard(_ text: String) {
        run("sendClipboard(text)", ["text": text])
    }

    func screenshot() async -> Data? {
        guard connected,
              let result = try? await web?.callAsyncJavaScript("return screenshot()", arguments: [:], in: nil, contentWorld: .page),
              let uri = result as? String, let payload = uri.split(separator: ",", maxSplits: 1).last else { return nil }
        return Data(base64Encoded: String(payload))
    }

    private func run(_ script: String, _ arguments: [String: Any]) {
        guard connected else { return }
        web?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    private func fail(_ message: String) { stop(); status = message }
    func stop() {
        #if os(iOS)
        pictureInPicture.reset()
        #endif
        mirrorVideo.reset()
        cancelFocusRequest()
        timeout?.cancel(); timeout = nil
        transport?.stateUpdateHandler = nil; transport?.cancel(); transport = nil
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "desktop")
        web?.navigationDelegate = nil; web?.stopLoading(); web = nil
        authenticated = nil; credentials.removeAll(); connected = false; resolution = ""; canResetViewport = false
    }
}
