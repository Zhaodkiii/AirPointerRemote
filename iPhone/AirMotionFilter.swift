import Foundation
import simd

/// Converts the phone's top-edge direction into continuous relative cursor motion.
struct AirMotionFilter {
    private var previousAim: SIMD2<Double>?
    private var previousTime: Double?
    private var filteredVelocity = SIMD2<Double>.zero

    mutating func reset() {
        previousAim = nil
        previousTime = nil
        filteredVelocity = .zero
    }

    mutating func sample(orientation: simd_quatd, time: Double, scale: Double) -> SIMD2<Double>? {
        let top = orientation.act(SIMD3<Double>(0, 1, 0))
        let horizontal = hypot(top.x, top.y)
        guard horizontal > 0.15 else { reset(); return nil }
        let aim = SIMD2(atan2(top.x, top.y), atan2(top.z, horizontal))
        defer { previousAim = aim; previousTime = time }
        guard let previousAim, let previousTime else { return nil }
        let dt = time - previousTime
        guard dt > 0, dt < 0.1 else { filteredVelocity = .zero; return nil }
        let delta = SIMD2(atan2(sin(aim.x - previousAim.x), cos(aim.x - previousAim.x)), -(aim.y - previousAim.y))
        guard abs(delta.x) < 0.3, abs(delta.y) < 0.3 else { filteredVelocity = .zero; return nil }
        let velocity = simd_length(delta) / dt
        if velocity < 0.012 {
            filteredVelocity = .zero
            return .zero
        }
        let cutoff = 4 + 12 * min(velocity, 3)
        let alpha = 1 - exp(-2 * Double.pi * cutoff * dt)
        filteredVelocity += alpha * (delta / dt - filteredVelocity)
        return filteredVelocity * dt * scale
    }
}
