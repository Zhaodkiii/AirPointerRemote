import Foundation
import Network
import SwiftUI

struct DesktopComputer: Identifiable, Codable, Hashable {
    let name: String
    let host: String
    let port: UInt16
    let domain: String?
    var id: NWEndpoint { endpoint }
    var endpoint: NWEndpoint {
        if let domain { return .service(name: host, type: "_rfb._tcp", domain: domain, interface: nil) }
        return .hostPort(host: .init(host), port: .init(rawValue: port)!)
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "vnc://" + value
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "vnc",
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path), let port = UInt16(exactly: parts.port ?? 5900), port > 0 else { return nil }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Self(name: bare, host: bare, port: port, domain: nil)
    }
}

final class DesktopDiscovery: ObservableObject {
    @Published var nearby: [DesktopComputer] = []
    @Published var status = String(localized: "Looking for Macs with Screen Sharing…")
    private var browser: NWBrowser?
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let devices = results.compactMap { item -> DesktopComputer? in
                guard case let .service(name, _, domain, _) = item.endpoint else { return nil }
                return DesktopComputer(name: name, host: name, port: 5900, domain: domain)
            }
            self.nearby = Array(Set(devices)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .waiting, .failed: self.status = String(localized: "Check Wi-Fi and Local Network access, or enter the Mac’s address.")
            case .ready: self.status = String(localized: "Looking for Macs with Screen Sharing…")
            default: break
            }
        }
        browser.start(queue: .main)
    }
    func stop() { browser?.cancel(); browser = nil; nearby = [] }
}
