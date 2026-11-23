import Foundation

struct DesktopCredentials: Codable {
    let username: String
    let password: String
    let account: Bool

    private static func key(for computer: DesktopComputer) -> String {
        if let domain = computer.domain {
            return "screen-sharing.bonjour.\(domain.lowercased())/\(computer.host.lowercased())"
        }
        let host = computer.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "screen-sharing.host.\(host)/\(computer.port)"
    }

    static func load(for computer: DesktopComputer) -> Self? {
        guard let data = PhoneKeychain.read(key(for: computer)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(for computer: DesktopComputer) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return PhoneKeychain.save(data, account: Self.key(for: computer))
    }

    static func remove(for computer: DesktopComputer) {
        PhoneKeychain.remove(key(for: computer))
    }
}
