import Foundation
import Combine
import simd

/// State consumed by the renderer each frame.
struct SpatialState {
    /// Head rotation in view space (x right, y up, -z forward), smoothed.
    /// Maps a camera ray to its world direction in the recentered frame.
    var headMatrix: simd_float3x3 = matrix_identity_float3x3
    var zoomLevel: CGFloat = 1.0   // lean-to-zoom: 1.0 or zoomed-in target
    var isCalibrated: Bool = false
}

/// Smoothing presets for head tracking (One Euro filter parameters).
/// minCutoff governs stillness jitter (lower = calmer when still);
/// beta governs how quickly smoothing releases during fast motion
/// (higher = less lag when turning).
enum SpatialSmoothing: String, CaseIterable, Codable {
    case responsive, balanced, smooth

    // minCutoff must sit below ~1 Hz: ballistocardiac head motion (the
    // heartbeat) pulses at 1–1.5 Hz and is visible as line shimmer if it
    // passes the filter. beta compensates by opening the cutoff on real turns.
    var minCutoff: Float {
        switch self {
        case .responsive: return 1.0
        case .balanced: return 0.25
        case .smooth: return 0.1
        }
    }

    var beta: Float {
        switch self {
        case .responsive: return 1.5
        case .balanced: return 1.0
        case .smooth: return 0.7
        }
    }
}

/// Converts IMU orientation into a smoothed view-space head matrix, and
/// detects deliberate lean-in/lean-back gestures from earth-frame
/// acceleration to toggle zoom (the IMU can't track sustained translation,
/// so lean is a gesture, not a position).
final class SpatialTracker: ObservableObject {

    @Published private(set) var state = SpatialState()

    var smoothing: SpatialSmoothing = .balanced
    var leanToZoomEnabled: Bool = true
    var zoomedLevel: CGFloat = 1.5   // zoom applied after a lean-in gesture

    /// Follow mode: the screen's anchor chases the gaze direction, so the
    /// screen drifts back to center whenever the head settles.
    var followModeEnabled: Bool = false
    private var anchorQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private let followAlpha: Float = 0.01  // per-sample chase rate (~1.5s lazy glide)

    // One Euro filter state
    private var lastRawQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var angularSpeed: Float = 0    // low-passed, rad/s
    private let speedCutoff: Float = 1.0   // Hz, for the speed estimate itself

    // Basis change between view space (x right, y up, -z forward) and the
    // IMU's NED frame (x north/forward, y east, z down). headMatrix = Nᵀ·R·N.
    private let viewToNed = simd_float3x3(rows: [
        SIMD3<Float>(0, 0, -1),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, -1, 0),
    ])

    private var smoothedQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Lean gesture detection
    private var zoomTarget: CGFloat = 1.0
    private var currentZoom: CGFloat = 1.0
    private var accelBias: Float = 0        // slow EMA of forward accel (m/s²)
    private var leanVelocity: Float = 0     // leaky integral of forward accel
    private var debounceSamples: Int = 0
    private let sampleDt: Float = 1.0 / 60.0
    private let leanThreshold: Float = 0.22 // m/s of integrated forward motion

    private weak var imuService: XRealIMUService?
    private var cancellable: AnyCancellable?
    private var accelCancellable: AnyCancellable?
    private var connectionCancellable: AnyCancellable?

    /// Recenter on the first sample after every (re)connect, so the neutral
    /// pose comes from real data rather than a timer that may fire before
    /// the IMU is streaming.
    private var needsInitialRecenter = true

    init(imuService: XRealIMUService) {
        self.imuService = imuService

        cancellable = imuService.orientationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawQuat in
                guard let self else { return }
                if self.needsInitialRecenter {
                    self.needsInitialRecenter = false
                    self.recenter()
                    return
                }
                self.update(orientation: imuService.relativeOrientation)
            }

        accelCancellable = imuService.accelerationSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] earthAccel in
                self?.processLean(earthAccel: earthAccel)
            }

        connectionCancellable = imuService.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                if !connected {
                    self?.needsInitialRecenter = true
                }
            }
    }

    /// Reset tracker to center and recenter the IMU reference.
    func recenter() {
        imuService?.recenter()
        smoothedQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        lastRawQuat = smoothedQuat
        anchorQuat = smoothedQuat
        angularSpeed = 0
        zoomTarget = 1.0
        currentZoom = 1.0
        leanVelocity = 0
        state = SpatialState(headMatrix: matrix_identity_float3x3, zoomLevel: 1.0, isCalibrated: true)
    }

    /// One Euro helper: EMA alpha for a given cutoff frequency at our sample rate.
    private func filterAlpha(cutoff: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoff)
        return 1.0 / (1.0 + tau / sampleDt)
    }

    // MARK: - Private

    private func update(orientation: simd_quatf) {
        let target = simd_normalize(orientation)

        // One Euro filter: cutoff frequency scales with angular speed, so the
        // view is glassy-still when the head is still but tracks with minimal
        // lag during fast turns.
        let delta = lastRawQuat.inverse * target
        let deltaAngle = 2 * acos(min(1, abs(delta.real)))
        lastRawQuat = target

        angularSpeed += (deltaAngle / sampleDt - angularSpeed) * filterAlpha(cutoff: speedCutoff)

        let cutoff = smoothing.minCutoff + smoothing.beta * angularSpeed
        smoothedQuat = simd_slerp(smoothedQuat, target, filterAlpha(cutoff: cutoff))

        // Ease zoom toward its target (~250ms)
        currentZoom += (zoomTarget - currentZoom) * 0.08

        // Follow mode: render relative to a lazily-chasing anchor instead of
        // the fixed recentered frame — the screen trails turns, then recenters.
        var effectiveQuat = smoothedQuat
        if followModeEnabled {
            anchorQuat = simd_normalize(simd_slerp(anchorQuat, smoothedQuat, followAlpha))
            effectiveQuat = anchorQuat.inverse * smoothedQuat
        }

        let rotNed = simd_float3x3(effectiveQuat)
        let headMatrix = viewToNed.transpose * rotNed * viewToNed

        state = SpatialState(
            headMatrix: headMatrix,
            zoomLevel: currentZoom,
            isCalibrated: true
        )
    }

    /// Detect a deliberate lean-in (forward acceleration impulse) → zoom in,
    /// or lean-back → zoom out. `earthAccel` is gravity-removed acceleration
    /// in the earth NED frame, in g.
    private func processLean(earthAccel: SIMD3<Float>) {
        guard leanToZoomEnabled, let imuService else { return }

        // Screen-forward in the earth frame: recentered gaze, horizontal only.
        var forward = imuService.referenceOrientation.act(SIMD3<Float>(1, 0, 0))
        forward.z = 0
        let len = simd_length(forward)
        guard len > 0.01 else { return }
        forward /= len

        let accelMs2 = simd_dot(earthAccel, forward) * 9.81

        // Remove slow bias (sensor offset, posture), integrate with decay so
        // the velocity estimate spikes on impulses but bleeds back to zero.
        accelBias += (accelMs2 - accelBias) * 0.01
        leanVelocity = (leanVelocity + (accelMs2 - accelBias) * sampleDt) * 0.92

        if debounceSamples > 0 {
            debounceSamples -= 1
            return
        }

        if leanVelocity > leanThreshold, zoomTarget == 1.0 {
            zoomTarget = zoomedLevel   // lean in → zoom, holds until lean-back
            debounceSamples = 50       // ~0.8s: ignore the stop transient
            leanVelocity = 0
        } else if leanVelocity < -leanThreshold, zoomTarget > 1.0 {
            zoomTarget = 1.0
            debounceSamples = 50
            leanVelocity = 0
        }
    }
}
