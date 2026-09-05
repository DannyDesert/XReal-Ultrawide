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

    private func readLoop() {
        while isRunning, let dev = device {
            let err = device_imu_read(dev, 16) // 16ms timeout ≈ 60Hz

            if err == DEVICE_IMU_ERROR_UNPLUGGED {
                print("[IMU] Device unplugged")
                return // connectLoop will close the handle and reconnect
            }

            if err == DEVICE_IMU_ERROR_NO_ERROR, let ahrs = dev.pointee.ahrs {
                let q = device_imu_get_orientation(ahrs)
                let quat = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)

                DispatchQueue.main.async { [weak self] in
                    self?.orientation = quat
                }
                orientationSubject.send(quat)

                let a = device_imu_get_earth_acceleration(ahrs)
                accelerationSubject.send(SIMD3<Float>(a.x, a.y, a.z))
            }
        }
    }
}
