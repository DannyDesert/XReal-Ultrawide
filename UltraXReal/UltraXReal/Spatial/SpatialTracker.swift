import Foundation
import Combine
import simd

/// Viewport state derived from head tracking.
struct SpatialState {
    var viewportOffset: CGPoint = .zero  // pixel offset on the virtual canvas
    var zoomLevel: CGFloat = 1.0         // 1.0 = normal, up to 2.5x
    var isCalibrated: Bool = false
}

/// Sensitivity presets for head tracking.
enum SpatialSensitivity: String, CaseIterable, Codable {
    case low, medium, high

    /// Pixels per radian of yaw rotation.
    var pixelsPerRadian: CGFloat {
        switch self {
        case .low: return 400
        case .medium: return 800
        case .high: return 1200
        }
    }
}

/// Smoothing presets for head tracking.
enum SpatialSmoothing: String, CaseIterable, Codable {
    case responsive, balanced, smooth

    /// EMA alpha (higher = more responsive, lower = smoother).
    var alpha: CGFloat {
        switch self {
        case .responsive: return 0.3
        case .balanced: return 0.15
        case .smooth: return 0.05
        }
    }
}

/// Converts IMU quaternions into viewport offsets and zoom levels.
///
/// Subscribes to XRealIMUService orientation updates, extracts yaw/pitch,
/// applies dead zone + EMA smoothing, and maps to viewport coordinates.
final class SpatialTracker: ObservableObject {

    @Published private(set) var state = SpatialState()

    var sensitivity: SpatialSensitivity = .medium
    var smoothing: SpatialSmoothing = .balanced
    var leanToZoomEnabled: Bool = true
    var zoomSensitivity: CGFloat = 2.0
    var zoomThreshold: CGFloat = 0.15  // radians of pitch before zoom kicks in

    /// Canvas and viewport dimensions (set by SpatialRenderer).
    var canvasSize: CGSize = CGSize(width: 3840, height: 2160)
    var viewportSize: CGSize = CGSize(width: 1920, height: 1080)

    private let deadZone: CGFloat = 0.005  // ~0.3 degrees in radians
    private var smoothedYaw: CGFloat = 0
    private var smoothedPitch: CGFloat = 0
    private var neutralPitch: CGFloat = 0

    private weak var imuService: XRealIMUService?
    private var cancellable: AnyCancellable?

    init(imuService: XRealIMUService) {
        self.imuService = imuService

        cancellable = imuService.orientationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawQuat in
                guard let self else { return }
                let relQuat = imuService.relativeOrientation
                self.update(orientation: relQuat)
            }
    }

    /// Reset tracker to center and recenter the IMU reference.
    func recenter() {
        imuService?.recenter()
        smoothedYaw = 0
        smoothedPitch = 0
        neutralPitch = 0
        state = SpatialState(viewportOffset: .zero, zoomLevel: 1.0, isCalibrated: true)
    }

    // MARK: - Private

    private func update(orientation: simd_quatf) {
        // Extract yaw and pitch from quaternion (ZYX Euler convention)
        let (yaw, pitch) = eulerAngles(from: orientation)

        // Dead zone: ignore micro-movements
        let filteredYaw = abs(yaw - smoothedYaw) > deadZone ? yaw : smoothedYaw
        let filteredPitch = abs(pitch - smoothedPitch) > deadZone ? pitch : smoothedPitch

        // Exponential moving average
        let alpha = smoothing.alpha
        smoothedYaw += (filteredYaw - smoothedYaw) * alpha
        smoothedPitch += (filteredPitch - smoothedPitch) * alpha

        // Map to viewport offset (head right → viewport shifts left)
        let maxOffsetX = canvasSize.width - viewportSize.width
        let maxOffsetY = canvasSize.height - viewportSize.height
        let centerX = maxOffsetX / 2
        let centerY = maxOffsetY / 2

        var offsetX = centerX - (smoothedYaw * sensitivity.pixelsPerRadian)
        var offsetY = centerY + (smoothedPitch * sensitivity.pixelsPerRadian)

        offsetX = max(0, min(offsetX, maxOffsetX))
        offsetY = max(0, min(offsetY, maxOffsetY))

        // Lean-to-zoom: pitch delta from neutral as depth proxy
        var zoom: CGFloat = 1.0
        if leanToZoomEnabled {
            let pitchDelta = smoothedPitch - neutralPitch
            if pitchDelta > zoomThreshold {
                zoom = 1.0 + (pitchDelta - zoomThreshold) * zoomSensitivity
                zoom = min(zoom, 2.5)
            }
        }

        state = SpatialState(
            viewportOffset: CGPoint(x: offsetX, y: offsetY),
            zoomLevel: zoom,
            isCalibrated: true
        )
    }

    /// Extract yaw and pitch from a quaternion (ZYX Euler convention).
    private func eulerAngles(from q: simd_quatf) -> (yaw: CGFloat, pitch: CGFloat) {
        let ix = q.imag.x
        let iy = q.imag.y
        let iz = q.imag.z
        let r = q.real

        // Yaw (Z-axis rotation)
        let siny = 2.0 * (r * iz + ix * iy)
        let cosy = 1.0 - 2.0 * (iy * iy + iz * iz)
        let yaw = CGFloat(atan2(siny, cosy))

        // Pitch (Y-axis rotation)
        let sinp = 2.0 * (r * iy - iz * ix)
        let pitch: CGFloat
        if abs(sinp) >= 1 {
            pitch = CGFloat(copysign(Float.pi / 2, sinp))
        } else {
            pitch = CGFloat(asin(sinp))
        }

        return (yaw, pitch)
    }
}
