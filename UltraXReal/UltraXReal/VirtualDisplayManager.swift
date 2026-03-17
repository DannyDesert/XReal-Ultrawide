import AppKit
import CoreGraphics
import Combine
import UserNotifications

/// Manages the lifecycle of a CGVirtualDisplay instance.
///
/// Creates, configures, and tears down virtual displays using Apple's
/// private CGVirtualDisplay API (exposed via bridging header).
/// Handles sleep/wake and app termination.
final class VirtualDisplayManager: ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var currentDisplayID: CGDirectDisplayID?
    @Published private(set) var lastError: String?

    private var virtualDisplay: CGVirtualDisplay?
    private let displayQueue = DispatchQueue(label: "com.ultraxreal.display", qos: .userInitiated)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var wasActiveBeforeSleep = false

    init() {
        setupSleepWakeObservers()
        requestNotificationPermission()
    }

    deinit {
        destroyDisplay()
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Public

    func enable(resolution: DisplayResolution) {
        guard !isActive else { return }
        lastError = nil

        displayQueue.async { [weak self] in
            self?.createDisplay(resolution: resolution)
        }
    }

    func disable() {
        displayQueue.async { [weak self] in
            self?.destroyDisplay()
        }
    }

    func changeResolution(_ resolution: DisplayResolution) {
        if isActive {
            disable()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enable(resolution: resolution)
            }
        }
    }

    /// Create a large virtual canvas for spatial mode.
    /// Physical size capped at 597×336mm for ScreenCaptureKit compatibility.
    func enableSpatialCanvas(width: UInt32 = 3840, height: UInt32 = 2160) {
        guard !isActive else { return }
        lastError = nil

        displayQueue.async { [weak self] in
            self?.createSpatialDisplay(width: width, height: height)
        }
    }

    private func createSpatialDisplay(width: UInt32, height: UInt32) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.vendorID = 0x1234
        descriptor.productID = 0x5679  // Different product ID to distinguish from static mode
        descriptor.serialNum = 2
        descriptor.name = "UltraXReal Spatial"
        descriptor.sizeInMillimeters = CGSize(width: 597, height: 336)  // 27" equivalent, SCK-safe
        descriptor.maxPixelsWide = width
        descriptor.maxPixelsHigh = height
        descriptor.queue = displayQueue

        guard let nativeMode = CGVirtualDisplayMode(
            width: width, height: height, refreshRate: 60.0
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Failed to create spatial display mode."
                self?.postErrorNotification(self?.lastError ?? "Unknown error")
            }
            return
        }

        let settings = CGVirtualDisplaySettings()
        settings.modes = [nativeMode]

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Failed to create spatial virtual display."
                self?.postErrorNotification(self?.lastError ?? "Unknown error")
            }
            return
        }

        let applied = display.apply(settings)
        if !applied {
            print("Warning: spatial display apply(settings) returned false")
        }

        let displayID = display.displayID

        DispatchQueue.main.async { [weak self] in
            self?.virtualDisplay = display
            self?.isActive = true
            self?.currentDisplayID = displayID
        }
    }

    // MARK: - Private: Display creation via bridging header

    private func createDisplay(resolution: DisplayResolution) {
        // Create descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.vendorID = 0x1234
        descriptor.productID = 0x5678
        descriptor.serialNum = 1
        descriptor.name = "UltraXReal"
        descriptor.sizeInMillimeters = resolution.sizeInMillimeters
        descriptor.maxPixelsWide = resolution.width
        descriptor.maxPixelsHigh = resolution.height
        descriptor.queue = displayQueue

        // Create display modes
        guard let nativeMode = CGVirtualDisplayMode(
            width: resolution.width,
            height: resolution.height,
            refreshRate: resolution.refreshRate
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Failed to create display mode."
                self?.postErrorNotification(self?.lastError ?? "Unknown error")
            }
            return
        }

        // Create settings with available modes
        let settings = CGVirtualDisplaySettings()
        settings.modes = [nativeMode]

        // Create virtual display
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Failed to create virtual display. Ensure macOS 13.0+ is installed."
                self?.postErrorNotification(self?.lastError ?? "Unknown error")
            }
            return
        }

        // Apply settings (modes)
        let applied = display.apply(settings)
        if !applied {
            print("Warning: apply(settings) returned false — display may not have all modes available.")
        }

        let displayID = display.displayID

        DispatchQueue.main.async { [weak self] in
            self?.virtualDisplay = display
            self?.isActive = true
            self?.currentDisplayID = displayID
        }
    }

    private func destroyDisplay() {
        DispatchQueue.main.async { [weak self] in
            // Releasing the CGVirtualDisplay tears it down from the system
            self?.virtualDisplay = nil
            self?.isActive = false
            self?.currentDisplayID = nil
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.wasActiveBeforeSleep = self.isActive
            if self.isActive {
                self.disable()
            }
        }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.wasActiveBeforeSleep {
                let res = Settings.shared.selectedResolution
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.enable(resolution: res)
                }
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func postErrorNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "UltraXReal"
        content.body = message

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
