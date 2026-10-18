import Foundation
import Combine
import simd

/// Wraps the xrealair-sdk-macos C driver to publish IMU orientation data.
///
/// Reads gyroscope + accelerometer from XReal Air glasses over USB HID,
/// runs Madgwick sensor fusion, and publishes quaternion orientation at ~60Hz.
final class XRealIMUService: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    private(set) var sampleInterval: Float = 1 / 60
    private(set) var sampleTime: TimeInterval = 0

    let orientationSubject = PassthroughSubject<simd_quatf, Never>()

    /// Gravity-removed acceleration in the earth NED frame, in g.
    let accelerationSubject = PassthroughSubject<SIMD3<Float>, Never>()

    /// The "zero" orientation captured by recenter(); identity until then.
    var referenceOrientation: simd_quatf { referenceQuat }

    private var device: UnsafeMutablePointer<device_imu_type>?
    private var readQueue: DispatchQueue?
    private var isRunning = false
    private var referenceQuat: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var hasReference = false
    private let calibrationLock = NSLock()
    private var calibrationRequest: (id: UUID, completion: (String?) -> Void)?
    private(set) var isCalibrating = false

    // Store a reference to self for the C callback context
    private var callbackContext: UnsafeMutableRawPointer?

    deinit {
        stop()
    }

    // MARK: - Public

    /// Check if any XReal glasses are connected (without opening the device).
    static func isDeviceAvailable() -> Bool {
        if !device_init() { return false }
        defer { device_exit() }

        let info = hid_enumerate(xreal_vendor_id, 0)
        let found = info != nil
        hid_free_enumeration(info)
        return found
    }

    /// Open the HID connection and start reading IMU data on a background thread.
    /// Retries the open (and reopens after USB re-enumeration) while running —
    /// the glasses briefly drop their HID interfaces when the display topology
    /// changes, e.g. right after the spatial canvas is created or mirroring toggles.
    func start() {
        guard !isRunning else { return }

        isRunning = true
        readQueue = DispatchQueue(label: "com.ultraxreal.imu", qos: .userInteractive)
        readQueue?.async { [weak self] in
            self?.connectLoop()
        }
    }

    private func connectLoop() {
        while isRunning {
            let dev = UnsafeMutablePointer<device_imu_type>.allocate(capacity: 1)
            dev.initialize(to: device_imu_type())

            let err = device_imu_open(dev, { timestamp, event, ahrs in
                // This C callback is invoked from the HID read thread.
                // We don't use it directly — we poll orientation after each read.
            })

            if err != DEVICE_IMU_ERROR_NO_ERROR {
                print("[IMU] Failed to open device: error \(err.rawValue) — retrying in 1s")
                dev.deallocate()
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            device = dev
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = true
            }

            readLoop()
            finishCalibration(error: "The glasses disconnected before calibration finished.")

            // readLoop returned: either stop() was requested or the device
            // unplugged (USB re-enumeration). Close and, if still running, reconnect.
            if let d = device {
                device_imu_close(d)
                d.deallocate()
                device = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }

            if isRunning {
                print("[IMU] Device lost — reconnecting")
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    /// Stop reading and close the HID connection.
    /// The connect loop owns the device handle and closes it on exit.
    func stop() {
        isRunning = false
        callbackContext = nil
        finishCalibration(error: "Calibration was cancelled.")

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
    }

    /// Capture current orientation as the "zero" reference point.
    /// All subsequent orientations will be relative to this.
    func recenter() {
        referenceQuat = orientation
        hasReference = true
    }

    /// Orientation relative to the reference (identity if not recentered).
    var relativeOrientation: simd_quatf {
        if hasReference {
            return referenceQuat.inverse * orientation
        }
        return orientation
    }

    // MARK: - Private

    /// Explicit user-requested calibration; the HID read loop remains the sole device owner.
    func calibrateGyroscope(completion: @escaping (String?) -> Void) {
        guard isConnected, !isCalibrating else {
            completion("Connect the glasses and wait for any current calibration to finish.")
            return
        }
        isCalibrating = true
        calibrationLock.lock()
        calibrationRequest = (UUID(), completion)
        calibrationLock.unlock()
    }

    private func finishCalibration(id: UUID? = nil, error: String?) {
        calibrationLock.lock()
        let request = calibrationRequest
        if let id, request?.id != id { calibrationLock.unlock(); return }
        calibrationRequest = nil
        calibrationLock.unlock()
        guard let request else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isCalibrating = false
            request.completion(error)
        }
    }

    private func biasKey(for dev: UnsafeMutablePointer<device_imu_type>) -> String? {
        guard let serial = dev.pointee.serial_number else { return nil }
        let serialString = String(cString: serial)
        guard !serialString.isEmpty else { return nil }
        return "gyroBias.v1.\(dev.pointee.vendor_id).\(dev.pointee.product_id).\(serialString)"
    }

    private func readLoop() {
        var previousTimestamp: UInt64 = 0
        var calibrationID: UUID?
        var calibrationDeadline: TimeInterval = 0
        if let dev = device, let rawOffset = dev.pointee.offset,
           let key = biasKey(for: dev), let bias = UserDefaults.standard.array(forKey: key) as? [Double],
           bias.count == 3, bias.allSatisfy({ $0.isFinite && abs($0) <= 3 }) {
            FusionOffsetSetBias(rawOffset.assumingMemoryBound(to: FusionOffset.self),
                                Float(bias[0]), Float(bias[1]), Float(bias[2]))
        }
        while isRunning, let dev = device {
            calibrationLock.lock()
            let requestID = calibrationRequest?.id
            calibrationLock.unlock()
            if requestID == nil, calibrationID != nil, let rawOffset = dev.pointee.offset {
                FusionOffsetCancelCalibration(rawOffset.assumingMemoryBound(to: FusionOffset.self))
                calibrationID = nil
            }
            if let requestID, requestID != calibrationID, let rawOffset = dev.pointee.offset {
                calibrationID = requestID
                calibrationDeadline = ProcessInfo.processInfo.systemUptime + 5
                FusionOffsetBeginCalibration(rawOffset.assumingMemoryBound(to: FusionOffset.self))
            }
            let err = device_imu_read(dev, 16) // 16ms timeout ≈ 60Hz

            if let calibrationID, requestID == calibrationID, let rawOffset = dev.pointee.offset {
                let offset = rawOffset.assumingMemoryBound(to: FusionOffset.self)
                let status = FusionOffsetGetCalibrationState(offset)
                if status == FusionOffsetCalibrationComplete {
                    let bias = FusionOffsetGetBias(offset)
                    if let key = biasKey(for: dev) {
                        UserDefaults.standard.set([Double(bias.axis.x), Double(bias.axis.y), Double(bias.axis.z)], forKey: key)
                    }
                    finishCalibration(id: calibrationID, error: nil)
                } else if status == FusionOffsetCalibrationMoved {
                    finishCalibration(id: calibrationID, error: "Movement was detected. Rest the glasses on a stable surface and try again.")
                } else if ProcessInfo.processInfo.systemUptime > calibrationDeadline {
                    FusionOffsetCancelCalibration(offset)
                    finishCalibration(id: calibrationID, error: "The sensor did not provide enough samples. Reconnect the glasses and retry.")
                }
            }

            if err == DEVICE_IMU_ERROR_UNPLUGGED {
                print("[IMU] Device unplugged")
                return // connectLoop will close the handle and reconnect
            }

            if err == DEVICE_IMU_ERROR_NO_ERROR, let ahrs = dev.pointee.ahrs {
                let q = device_imu_get_orientation(ahrs)
                let quat = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)

                let timestamp = dev.pointee.last_timestamp
                guard timestamp > previousTimestamp else { continue }
                let interval = previousTimestamp == 0 ? Float(1 / 60.0) : Float(timestamp - previousTimestamp) / 1e9
                previousTimestamp = timestamp
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let a = device_imu_get_earth_acceleration(ahrs)
                let acceleration = SIMD3<Float>(a.x, a.y, a.z)
                // Publish one coherent sample. A timeout must never republish stale orientation.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.sampleInterval = min(0.1, max(0.0001, interval))
                    self.sampleTime = receivedAt
                    self.orientation = quat
                    self.orientationSubject.send(quat)
                    self.accelerationSubject.send(acceleration)
                }
            }
        }
    }
}
