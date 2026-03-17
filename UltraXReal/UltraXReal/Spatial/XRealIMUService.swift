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
    func start() {
        guard !isRunning else { return }

        device = UnsafeMutablePointer<device_imu_type>.allocate(capacity: 1)
        device!.initialize(to: device_imu_type())

        // Store unretained pointer to self for the C callback
        callbackContext = Unmanaged.passUnretained(self).toOpaque()

        let err = device_imu_open(device!, { timestamp, event, ahrs in
            // This C callback is invoked from the HID read thread.
            // We don't use it directly — we poll orientation after each read.
        })

        if err != DEVICE_IMU_ERROR_NO_ERROR {
            print("[IMU] Failed to open device: error \(err.rawValue)")
            device?.deallocate()
            device = nil
            callbackContext = nil
            DispatchQueue.main.async { [weak self] in
                self?.isConnected = false
            }
            return
        }

        isRunning = true
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
        }

        readQueue = DispatchQueue(label: "com.ultraxreal.imu", qos: .userInteractive)
        readQueue?.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Stop reading and close the HID connection.
    func stop() {
        isRunning = false

        if let dev = device {
            device_imu_close(dev)
            dev.deallocate()
            device = nil
        }

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
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = false
                    self?.isRunning = false
                }
                return
            }

            if err == DEVICE_IMU_ERROR_NO_ERROR, let ahrs = dev.pointee.ahrs {
                let q = device_imu_get_orientation(ahrs)
                let quat = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)

                DispatchQueue.main.async { [weak self] in
                    self?.orientation = quat
                }
                orientationSubject.send(quat)
            }
        }
    }
}
