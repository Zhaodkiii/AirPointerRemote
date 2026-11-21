import Foundation

struct LinkedVideoQuality {
    struct Profile: Equatable {
        let bitrate: Int
        let fps: Int
        var longEdge: Int { bitrate <= 1_000_000 ? 960 : 1280 }
    }

    static let profiles = [
        Profile(bitrate: 3_000_000, fps: 30),
        Profile(bitrate: 1_800_000, fps: 30),
        Profile(bitrate: 1_000_000, fps: 30),
        Profile(bitrate: 1_000_000, fps: 20),
        Profile(bitrate: 1_000_000, fps: 15)
    ]

    private(set) var level = 0
    var profile: Profile { Self.profiles[level] }
    private var acknowledgements: [(time: TimeInterval, delay: TimeInterval)] = []
    private var lastEvaluation: TimeInterval = 0
    private var lastChange: TimeInterval = -.infinity
    private var lastSample: TimeInterval?
    private var goodSince: TimeInterval?
    private var congestedWindows = 0
    private var lastUpgrade: TimeInterval = -.infinity
    private var upgradeInterval: TimeInterval = 10
    private var fullSeconds: TimeInterval = 0

    mutating func record(now: TimeInterval, delay: TimeInterval) {
        acknowledgements.append((now, delay))
    }

    mutating func resetMeasurements() {
        acknowledgements.removeAll()
        lastSample = nil
        lastEvaluation = 0
        goodSince = nil
        congestedWindows = 0
        fullSeconds = 0
    }

    mutating func evaluate(now: TimeInterval, oldestAge: TimeInterval, windowFull: Bool) -> Int? {
        let elapsed = lastSample.map { min(0.4, now - $0) } ?? 0
        lastSample = now
        if windowFull { fullSeconds += elapsed }
        let minimumHold: TimeInterval = level >= 2 ? 4 : 2
        if oldestAge >= 0.35, now - lastChange >= minimumHold,
           level + 1 < Self.profiles.count {
            return level + 1
        }
        let interval = now - lastEvaluation
        guard interval >= 1 else { return nil }
        lastEvaluation = now
        let fullFraction = fullSeconds / interval
        fullSeconds = 0
        acknowledgements.removeAll { now - $0.time > 2 }
        let delays = acknowledgements.map(\.delay).sorted()
        guard delays.count >= 8 else {
            goodSince = nil
            congestedWindows = 0
            return nil
        }
        let p95 = delays[Int(ceil(Double(delays.count) * 0.95)) - 1]
        congestedWindows = p95 > 0.15 && fullFraction >= 0.3 ? congestedWindows + 1 : 0
        if congestedWindows >= 2, now - lastChange >= minimumHold, level + 1 < Self.profiles.count {
            return level + 1
        }
        guard p95 < 0.08, fullFraction < 0.1, oldestAge < 0.15 else {
            goodSince = nil
            return nil
        }
        if goodSince == nil { goodSince = now }
        if let goodSince, level > 0, now - goodSince >= upgradeInterval { return level - 1 }
        return nil
    }

    mutating func applied(_ next: Int, at now: TimeInterval) {
        if next < level {
            lastUpgrade = now
            upgradeInterval = 10
        } else if now - lastUpgrade < 3 {
            upgradeInterval = 20
        }
        level = next
        lastChange = now
        resetMeasurements()
    }
}
