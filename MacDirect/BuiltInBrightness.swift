import AppKit
import Darwin
import IOKit
import os

/// Tracks only the internal panel. The virtual desktop has no backlight.
final class BuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private let powerDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.daokaihua.airpointerremote.direct", category: "Brightness")
    private let savedKey = "lidDesktop.pendingBrightnessRestore"
    private var display: CGDirectDisplayID?
    private var openBrightness: Float?
    private var needsRestore: Float?
    private var wasClosed = false
    private var dimmed = false

    init() {
        if let stored = defaults.object(forKey: savedKey) as? NSNumber {
            needsRestore = stored.floatValue
        }
    }

    deinit {
        if powerDomain != 0 { IOObjectRelease(powerDomain) }
        if let library { dlclose(library) }
    }

    var lidClosed: Bool? {
        guard powerDomain != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(powerDomain, "AppleClamshellState" as CFString,
                                                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func builtInDisplay() -> CGDirectDisplayID? {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
        }.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private func read(_ id: CGDirectDisplayID) -> Float? {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        let get = unsafeBitCast(symbol, to: GetBrightness.self)
        var value: Float = 0
        guard get(id, &value) == 0, (0...1).contains(value) else { return nil }
        return value
    }

    private func write(_ value: Float, to id: CGDirectDisplayID) -> Bool {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return false }
        let set = unsafeBitCast(symbol, to: SetBrightness.self)
        return set(id, value) == 0
    }

    func update(enabled: Bool) {
        guard let lidClosed else { return }
        if !lidClosed {
            guard let id = builtInDisplay() else { return }
            display = id
            if let brightness = needsRestore {
                guard write(brightness, to: id) else { return }
                defaults.removeObject(forKey: savedKey)
                needsRestore = nil
                openBrightness = brightness
                log.notice("Restored internal display brightness")
            } else if enabled {
                openBrightness = read(id) ?? openBrightness
            }
            wasClosed = false
            dimmed = false
            return
        }

        guard enabled else {
            openBrightness = nil
            return
        }
        if !wasClosed {
            wasClosed = true
            if let brightness = openBrightness, needsRestore == nil {
                needsRestore = brightness
                defaults.set(brightness, forKey: savedKey)
            }
        }
        // macOS may disconnect the internal panel before this callback. Its
        // backlight is already off in that case. Retry while it remains addressable.
        if !dimmed, needsRestore != nil, let display, CGDisplayIsBuiltin(display) != 0 {
            dimmed = write(0, to: display)
            if dimmed { log.notice("Set internal display brightness to minimum") }
        }
    }

}
