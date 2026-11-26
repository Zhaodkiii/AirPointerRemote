import Darwin
import Foundation
import IOKit
import IOKit.ps
import OSLog
import SystemConfiguration

/// Serialized on the main queue. The daemon owns the change until its XPC client
/// ends the session, disconnects, or stops renewing it.
private final class PowerManager {
    private let directory = "/private/var/run/com.daokaihua.liddesktop"
    private let recoveryFile = "/private/var/db/cn.zhaodk.glidecue.direct.sleep"
    private let log = Logger(subsystem: LidPowerService.identifier, category: "Power")
    private var owner: UUID?
    private var renewedAt: TimeInterval = 0
    private var endAt: TimeInterval = 0
    private var endReason: String?
    private var hasDirectory = false

    init() {
        recoverIfNeeded()
    }

    func begin(_ id: UUID, uid: uid_t) -> String? {
        if owner == id { return renew(id, uid: uid) }
        guard owner == nil, isConsoleUser(uid) else { return "Closed-lid power is unavailable for this session." }
        guard batteryAllowsSharing() else { return "Charge your Mac above 15% or connect power before sharing." }
        recoverIfNeeded()
        guard mkdir(directory, 0o755) == 0 else {
            return "Stop the separate Lid Desktop app or finish restoring sleep before trying again."
        }
        hasDirectory = true
        guard let previous = sleepDisabled() else {
            _ = restore()
            return "Could not read the current Mac sleep setting."
        }
        do {
            try Data([previous ? 1 : 0]).write(to: URL(fileURLWithPath: recoveryFile), options: .atomic)
        } catch {
            _ = restore()
            return "Could not save the previous Mac sleep setting."
        }
        if !previous && !setSleepDisabled(true) {
            _ = restore()
            return "Could not keep the Mac awake with the lid closed."
        }
        owner = id
        endReason = nil
        renewedAt = ProcessInfo.processInfo.systemUptime
        endAt = renewedAt + 7_200
        return nil
    }

    func renew(_ id: UUID, uid: uid_t) -> String? {
        guard isConsoleUser(uid) else {
            end(id)
            return "The Mac user session changed. Start sharing again."
        }
        tick()
        guard owner == id else { return endReason ?? "The closed-lid power session ended." }
        renewedAt = ProcessInfo.processInfo.systemUptime
        return nil
    }

    @discardableResult func end(_ id: UUID) -> String? {
        if owner == id {
            owner = nil
            return restore() ? nil : "Mac sleep is being restored. Check the Mac before closing the lid."
        }
        return nil
    }

    func tick() {
        guard let owner else {
            if hasDirectory || FileManager.default.fileExists(atPath: recoveryFile) { recoverIfNeeded() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= endAt {
            endReason = "Closed-lid sharing reached its two-hour limit."
        } else if !batteryAllowsSharing() {
            endReason = "Closed-lid sharing ended because Mac battery reached 15%."
        } else if now - renewedAt >= 12 {
            endReason = "The Mac app stopped responding. Normal sleep was restored."
        } else {
            return
        }
        end(owner)
    }

    var warning: String? {
        if let percent = batteryPercent(), percent <= 20 {
            return "Mac battery is low. Connect power to keep sharing."
        }
        if endAt - ProcessInfo.processInfo.systemUptime <= 300 {
            return "This closed-lid session ends in less than five minutes."
        }
        return nil
    }

    private func recoverIfNeeded() {
        if hasDirectory || FileManager.default.fileExists(atPath: recoveryFile) { _ = restore() }
    }

    private func restore() -> Bool {
        let legacyActive = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .contains { $0.hasPrefix("ready-") } ?? false
        guard !legacyActive else { return false }
        let record = try? Data(contentsOf: URL(fileURLWithPath: recoveryFile))
        if record == Data([0]), sleepDisabled() != false, !setSleepDisabled(false) {
            log.error("Could not restore the Mac sleep setting. Will retry.")
            return false
        }
        if rmdir(directory) != 0 && errno != ENOENT {
            log.error("Could not remove the power session directory. Will retry.")
            return false
        }
        if record != nil, unlink(recoveryFile) != 0 && errno != ENOENT {
            return false
        }
        hasDirectory = false
        return true
    }

    private func sleepDisabled() -> Bool? {
        let domain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard domain != 0 else { return nil }
        defer { IOObjectRelease(domain) }
        return IORegistryEntryCreateCFProperty(domain, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        tool.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        do { try tool.run() } catch { return false }
        tool.waitUntilExit()
        return tool.terminationStatus == 0 && sleepDisabled() == disabled
    }

    private func batteryAllowsSharing() -> Bool { (batteryPercent() ?? 0) > 15 }

    private func batteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        if IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String == kIOPMACPowerKey { return 100 }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = info[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = info[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
            return Int(100 * capacity / maximum)
        }
        return nil
    }
}

private func isConsoleUser(_ uid: uid_t) -> Bool {
    var consoleUID: uid_t = 0
    _ = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil)
    return uid != 0 && uid == consoleUID
}

private final class PowerClient: NSObject, LidPowerProtocol {
    let id = UUID()
    let manager: PowerManager
    let uid: uid_t

    init(_ manager: PowerManager, uid: uid_t) {
        self.manager = manager
        self.uid = uid
    }

    func begin(reply: @escaping (String?) -> Void) { DispatchQueue.main.async { reply(self.manager.begin(self.id, uid: self.uid)) } }
    func renew(reply: @escaping (String?, String?) -> Void) {
        DispatchQueue.main.async {
            let reason = self.manager.renew(self.id, uid: self.uid)
            reply(reason, reason == nil ? self.manager.warning : nil)
        }
    }
    func end(reply: @escaping (String?) -> Void) { DispatchQueue.main.async { reply(self.manager.end(self.id)) } }
}

private final class Daemon: NSObject, NSXPCListenerDelegate {
    let manager = PowerManager()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isConsoleUser(connection.effectiveUserIdentifier) else { return false }
        let client = PowerClient(manager, uid: connection.effectiveUserIdentifier)
        connection.exportedInterface = NSXPCInterface(with: LidPowerProtocol.self)
        connection.exportedObject = client
        connection.invalidationHandler = { DispatchQueue.main.async { client.manager.end(client.id) } }
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else { exit(EXIT_FAILURE) }
private let daemon = Daemon()
let listener = NSXPCListener(machServiceName: LidPowerService.identifier)
listener.setConnectionCodeSigningRequirement(#"anchor apple generic and identifier "cn.zhaodk.glidecue.direct" and certificate leaf[subject.OU] = "4AN6PV98G7""#)
listener.delegate = daemon
listener.resume()
let watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in daemon.manager.tick() }
RunLoop.main.run()
