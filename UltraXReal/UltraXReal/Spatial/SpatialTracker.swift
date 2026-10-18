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
        case .responsive: return 40
        case .balanced: return 30
        case .smooth: return 20
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
    private var sampleTime: TimeInterval = 0
    private var angularVelocity = SIMD3<Float>.zero
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
    private var debounceRemaining: Float = 0
    private var sampleDt: Float = 1.0 / 60.0
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
            .sink { [weak self] rawQuat in
                guard let self else { return }
                if self.needsInitialRecenter {
                    self.needsInitialRecenter = false
                    self.recenter()
                    return
                }
                self.sampleDt = imuService.sampleInterval
                self.sampleTime = imuService.sampleTime
                self.update(orientation: imuService.referenceOrientation.inverse * rawQuat)
            }

        accelCancellable = imuService.accelerationSubject
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
        angularVelocity = .zero
        sampleTime = 0
        zoomTarget = 1.0
        currentZoom = 1.0
        leanVelocity = 0
        accelBias = 0
        debounceRemaining = 0
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
        var delta = simd_normalize(lastRawQuat.inverse * target)
        if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
        let deltaAngle = 2 * atan2(simd_length(delta.imag), max(0, delta.real))
        let velocity = deltaAngle > 0.000001 ? delta.imag / simd_length(delta.imag) * (deltaAngle / sampleDt) : .zero
        angularVelocity += (velocity - angularVelocity) * filterAlpha(cutoff: 20)
        lastRawQuat = target

        angularSpeed += (deltaAngle / sampleDt - angularSpeed) * filterAlpha(cutoff: speedCutoff)

        let cutoff = smoothing.minCutoff + smoothing.beta * angularSpeed
        smoothedQuat = simd_slerp(smoothedQuat, target, filterAlpha(cutoff: cutoff))

        // Ease zoom toward its target (~250ms)
        currentZoom += (zoomTarget - currentZoom) * (1 - pow(0.92, CGFloat(sampleDt * 60)))

        // Follow mode: render relative to a lazily-chasing anchor instead of
        // the fixed recentered frame — the screen trails turns, then recenters.
        var effectiveQuat = smoothedQuat
        if followModeEnabled {
            anchorQuat = simd_normalize(simd_slerp(anchorQuat, smoothedQuat, 1 - pow(1 - followAlpha, sampleDt * 60)))
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

    /// Evaluate orientation at presentation time instead of holding each USB sample for a frame.
    func presentationState(at time: TimeInterval) -> SpatialState {
        guard sampleTime > 0, time - sampleTime < 0.05, !followModeEnabled else { return state }
        let speed = simd_length(angularVelocity)
        guard speed > 0.01 else { return state }
        let cutoff = smoothing.minCutoff + smoothing.beta * angularSpeed
        let filterDelay = min(0.025, 1 / (2 * Float.pi * cutoff))
        let horizon = min(0.035, max(0, Float(time - sampleTime)) + filterDelay)
        let predicted = smoothedQuat * simd_quatf(angle: min(0.12, speed * horizon), axis: angularVelocity / speed)
        var result = state
        result.headMatrix = viewToNed.transpose * simd_float3x3(predicted) * viewToNed
        return result
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
        accelBias += (accelMs2 - accelBias) * (1 - pow(0.99, sampleDt * 60))
        leanVelocity = (leanVelocity + (accelMs2 - accelBias) * sampleDt) * pow(0.92, sampleDt * 60)

        if debounceRemaining > 0 {
            debounceRemaining -= sampleDt
            return
        }

        if leanVelocity > leanThreshold, zoomTarget == 1.0 {
            zoomTarget = zoomedLevel   // lean in → zoom, holds until lean-back
            debounceRemaining = 50 / 60.0       // ~0.8s: ignore the stop transient
            leanVelocity = 0
        } else if leanVelocity < -leanThreshold, zoomTarget > 1.0 {
            zoomTarget = 1.0
            debounceRemaining = 50 / 60.0
            leanVelocity = 0
        }
    }
}
