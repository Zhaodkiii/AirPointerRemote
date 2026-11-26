import SwiftUI
import rootshellVNC

/// Resolves the SRV target and port; a Bonjour instance name can differ from the Mac's hostname.
private final class DesktopServiceResolver: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var completion: CheckedContinuation<(String, UInt16), Error>?

    @MainActor
    func address(for computer: DesktopComputer) async throws -> (String, UInt16) {
        guard let domain = computer.domain else { return (computer.host, computer.port) }
        let service = NetService(domain: domain, type: "_rfb._tcp.", name: computer.host)
        self.service = service
        defer { service.stop(); service.delegate = nil; self.service = nil }
        return try await withCheckedThrowingContinuation {
            completion = $0
            service.delegate = self
            service.resolve(withTimeout: 6)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, let port = UInt16(exactly: sender.port), port > 0 else {
            finish(.failure(URLError(.cannotFindHost)))
            return
        }
        finish(.success((host, port)))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(URLError(.cannotFindHost)))
    }

    private func finish(_ result: Result<(String, UInt16), Error>) {
        completion?.resume(with: result)
        completion = nil
    }
}

@MainActor
@Observable
final class HighPerformanceDesktop {
    private(set) var session = VNCSession(configuration: HighPerformanceDesktop.configuration)
    let pictureInPicture = DesktopPictureInPicture()
    private(set) var connecting = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var offersMirror = false
    private(set) var credentialsRejected = false
    private var attempt: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var viewport = CGSize.zero
    private var scale: CGFloat = 1

    private static var configuration: VNCConfiguration {
        VNCConfiguration(videoQualityMode: .adaptive, displaySizingMode: .matchClient,
                         displayMode: .oneDisplay, remoteSystem: .mac,
                         reconnectionPolicy: .init(isEnabled: false), securityPolicy: .macAuthentication)
    }

    func resize(_ size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        self.scale = scale
        session.updateRemoteDisplaySize(viewSize: size, displayScale: scale)
    }

    func start(_ computer: DesktopComputer, credentials: DesktopCredentials, connected: @escaping () -> Void) {
        stop()
        offersMirror = false
        credentialsRejected = false
        error = nil
        connecting = true
        let current = VNCSession(configuration: Self.configuration)
        session = current
        current.updateRemoteDisplaySize(viewSize: viewport, displayScale: scale)
        watchdog = Task {
            try? await Task.sleep(for: .seconds(40))
            guard !Task.isCancelled else { return }
            fail(String(localized: "The Mac did not establish a high-performance desktop at the iPhone’s aspect ratio."))
        }
        attempt = Task {
            do {
                let (host, port) = try await DesktopServiceResolver().address(for: computer)
                try Task.checkCancellation()
                try await current.connect(credentials: VNCCredentials(host: host, port: port,
                    password: credentials.password, username: credentials.username))
                while !Task.isCancelled {
                    if let reason = current.highPerformanceFallbackReason { fail(reason); return }
                    switch current.connectionState {
                    case .failed(let reason): fail(reason); return
                    case .disconnected: fail(String(localized: "The Mac disconnected.")); return
                    default: break
                    }
                    if !ready, current.connectionState.isConnected, current.isHighPerformanceMode,
                       current.framebufferHeight > 0, viewport.height > 0 {
                        let ratio = Double(current.framebufferWidth) / Double(current.framebufferHeight)
                        let desired = viewport.width / viewport.height
                        if abs(ratio / desired - 1) < 0.025,
                           await current.currentStatistics()?.framesDecoded ?? 0 > 0 {
                            try Task.checkCancellation()
                            ready = true
                            connecting = false
                            watchdog?.cancel()
                            connected()
                        }
                    }
                    if ready && !current.isHighPerformanceMode {
                        fail(String(localized: "High-performance screen sharing ended."))
                        return
                    }
                    try await Task.sleep(for: ready ? .seconds(1) : .milliseconds(200))
                }
            } catch {
                guard !Task.isCancelled else { return }
                if case VNCError.authenticationFailed(let reason) = error {
                    if reason == "The server does not offer the requested security method" {
                        offersMirror = true
                        fail(String(localized: "This Mac does not offer the authentication method required for a private desktop."))
                    } else {
                        credentialsRejected = true
                        fail(String(localized: "Check your Mac username, password and Screen Sharing access."))
                    }
                } else {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    func stop() {
        watchdog?.cancel()
        attempt?.cancel()
        session.disconnect()
        pictureInPicture.reset()
        connecting = false
        ready = false
    }
}
