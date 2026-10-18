import AppKit
import CoreGraphics
import Combine
import UserNotifications

/// Serializes ownership of virtual displays; public lifecycle state belongs to the main queue.
final class VirtualDisplayManager: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var currentDisplayID: CGDirectDisplayID?
    @Published private(set) var spatialDisplayIDs: [CGDirectDisplayID] = []
    @Published private(set) var lastError: String?

    private struct Specification {
        let name: String
        let product: UInt32
        let serial: UInt32
        let width: UInt32
        let height: UInt32
        let refreshRate: Double
        let size: CGSize
    }

    private enum DisplayError: LocalizedError {
        case failed(String)
        case cancelled
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            case .cancelled: return "Display startup cancelled."
            }
        }
    }

    // Read and release only on displayQueue.
    private var virtualDisplays: [CGVirtualDisplay] = []
    private var retiringDisplayIDs: Set<CGDirectDisplayID> = []
    private let displayQueue = DispatchQueue(label: "com.ultraxreal.display", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var isStarting = false
    private var isSpatialSession = false
    private var viewerPlacement: (id: CGDirectDisplayID, anchor: CGDirectDisplayID, offset: CGPoint)?
    private var cursorGuard: Timer?
    private var lastDesktopCursor: CGPoint?
    private var originalMainDisplayID: CGDirectDisplayID?
    private var staticResolutionBeforeSleep: DisplayResolution?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        setupSleepWakeObservers()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    deinit {
        if let observer = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func enable(resolution: DisplayResolution) {
        let specification = Specification(name: "UltraXReal", product: 0x5678, serial: 1,
                                          width: resolution.width, height: resolution.height,
                                          refreshRate: resolution.refreshRate, size: resolution.sizeInMillimeters)
        enable(specifications: [specification], spatial: false, arrange: false)
    }

    func enableSpatialCanvas(width: UInt32 = 3840, height: UInt32 = 2160) {
        let specification = Specification(name: "UltraXReal Spatial", product: 0x5679, serial: 2,
                                          width: width, height: height, refreshRate: 60,
                                          size: CGSize(width: 1194, height: 672))
        enable(specifications: [specification], spatial: true, arrange: false)
    }

    /// Creates independent desktop displays, returned in left-to-right order.
    func enableSpatialMonitors(count: Int, width: UInt32, height: UInt32,
                               completion: @escaping (Result<[CGDirectDisplayID], Error>) -> Void) {
        guard (1...3).contains(count), width > 0, height > 0 else {
            onMain { completion(.failure(DisplayError.failed("Choose one to three monitors with a valid resolution."))) }
            return
        }
        let names = count == 1 ? ["Center"] : count == 2 ? ["Left", "Right"] : ["Left", "Center", "Right"]
        let specifications = names.map { name in
            Specification(name: "UltraXReal \(name)", product: 0x567A,
                          serial: name == "Left" ? 10 : name == "Center" ? 11 : 12,
                          width: width, height: height, refreshRate: 60,
                          size: CGSize(width: 1194, height: 672))
        }
        enable(specifications: specifications, spatial: true, arrange: true, completion: completion)
    }

    func disable(completion: (() -> Void)? = nil) {
        onMain { [self] in
            generation &+= 1
            isStarting = false
            restoreMainDisplay()
            restoreViewerPlacement()
            currentDisplayID = nil
            spatialDisplayIDs = []
            isActive = false
            isSpatialSession = false
            staticResolutionBeforeSleep = nil
            displayQueue.async { [self] in
                let removedIDs = Set(virtualDisplays.map(\.displayID)).union(retiringDisplayIDs)
                virtualDisplays.removeAll()
                retiringDisplayIDs = []
                let removed = Self.waitForDisplayChange { Set(Self.onlineDisplayIDs()).isDisjoint(with: removedIDs) }
                DispatchQueue.main.async { [self] in
                    if !removed { lastError = "Virtual display removal is still pending in macOS." }
                    completion?()
                }
            }
        }
    }

    func changeResolution(_ resolution: DisplayResolution) {
        onMain { [self] in
            guard isActive else { return }
            disable { [weak self] in self?.enable(resolution: resolution) }
        }
    }

    /// Keep the physical glasses output outside the interactive desktop chain.
    @discardableResult
    func routeSpatialDesktop(viewerID: CGDirectDisplayID) -> Bool {
        guard Thread.isMainThread, !spatialDisplayIDs.isEmpty else { return false }
        let physical = Self.onlineDisplayIDs().filter {
            $0 != viewerID && !spatialDisplayIDs.contains($0) && CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == 0
        }
        guard let anchor = physical.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? physical.first else { return false }
        let anchorOrigin = CGDisplayBounds(anchor).origin
        let oldOrigin = CGDisplayBounds(viewerID).origin
        let bounds = physical.map { CGDisplayBounds($0) }
        let startX = bounds.map(\.maxX).max() ?? 0
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return false }
        var x = startX
        for id in spatialDisplayIDs {
            guard CGConfigureDisplayOrigin(configuration, id, Int32(x), Int32(anchorOrigin.y)) == .success else {
                CGCancelDisplayConfiguration(configuration)
                return false
            }
            x += CGDisplayBounds(id).width
        }
        // A disconnected output has no shared edge through which the pointer can travel.
        let parkedY = (bounds.map(\.minY).min() ?? 0) - CGDisplayBounds(viewerID).height - 4096
        guard CGConfigureDisplayOrigin(configuration, viewerID, Int32(anchorOrigin.x), Int32(parkedY)) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else { return false }
        viewerPlacement = (viewerID, anchor, CGPoint(x: oldOrigin.x - anchorOrigin.x, y: oldOrigin.y - anchorOrigin.y))
        cursorGuard?.invalidate()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            guard let self, let point = CGEvent(source: nil)?.location else { return }
            let interactive = Self.onlineDisplayIDs().filter { $0 != viewerID && CGDisplayIsActive($0) != 0 }
            if CGDisplayBounds(viewerID).contains(point) {
                let fallback = self.currentDisplayID.map { CGDisplayBounds($0) } ?? CGDisplayBounds(anchor)
                let previous = self.lastDesktopCursor.flatMap { saved in
                    interactive.contains(where: { CGDisplayBounds($0).contains(saved) }) ? saved : nil
                }
                CGWarpMouseCursorPosition(previous ?? CGPoint(x: fallback.midX, y: fallback.midY))
            } else if interactive.contains(where: { CGDisplayBounds($0).contains(point) }) {
                self.lastDesktopCursor = point
            }
        }
        cursorGuard = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func restoreViewerPlacement() {
        cursorGuard?.invalidate()
        cursorGuard = nil
        lastDesktopCursor = nil
        guard let placement = viewerPlacement else { return }
        viewerPlacement = nil
        let ids = Self.onlineDisplayIDs()
        guard ids.contains(placement.id), ids.contains(placement.anchor) else { return }
        let anchor = CGDisplayBounds(placement.anchor).origin
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return }
        guard CGConfigureDisplayOrigin(configuration, placement.id,
                                       Int32(anchor.x + placement.offset.x), Int32(anchor.y + placement.offset.y)) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return
        }
        if CGCompleteDisplayConfiguration(configuration, .forSession) != .success {
            lastError = "Could not restore the glasses display position."
        }
    }

    /// Moves the chosen display to desktop origin without changing relative monitor placement.
    @discardableResult
    func makeMainDisplay(_ id: CGDirectDisplayID) -> Bool {
        guard Thread.isMainThread, Self.onlineDisplayIDs().contains(id) else { return false }
        let previous = CGMainDisplayID()
        guard previous != id else { return true }
        guard Self.shiftDesktopOrigin(to: id) else { return false }
        if originalMainDisplayID == nil, !spatialDisplayIDs.contains(previous) {
            originalMainDisplayID = previous
        }
        return true
    }

    /// Restores the remembered physical primary display, or a connected built-in display.
    func restoreMainDisplay() {
        guard Thread.isMainThread else { return }
        guard spatialDisplayIDs.contains(CGMainDisplayID()) else {
            originalMainDisplayID = nil
            return
        }
        let physicalIDs = Self.onlineDisplayIDs().filter {
            !spatialDisplayIDs.contains($0) && CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == 0
        }
        let original = originalMainDisplayID.flatMap { original -> CGDirectDisplayID? in
            if physicalIDs.contains(original) { return original }
            let master = CGDisplayMirrorsDisplay(original)
            return physicalIDs.contains(master) ? master : nil
        }
        let target = original ?? physicalIDs.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? physicalIDs.first
        guard let target, Self.shiftDesktopOrigin(to: target) else {
            lastError = "Could not restore the original main display."
            return
        }
        originalMainDisplayID = nil
    }

    private func enable(specifications: [Specification], spatial: Bool, arrange: Bool,
                        completion: ((Result<[CGDirectDisplayID], Error>) -> Void)? = nil) {
        onMain { [self] in
            guard !isActive, !isStarting else {
                completion?(.failure(DisplayError.failed("A display session is already active or starting.")))
                return
            }
            generation &+= 1
            let token = generation
            isStarting = true
            isSpatialSession = spatial
            lastError = nil
            displayQueue.async { [self] in
                let result = Result { try self.createGroup(specifications, arrange: arrange) }
                if case .success(let displays) = result { self.virtualDisplays = displays }
                // Finish publication before another queued teardown or creation can reuse the serials.
                let accepted = DispatchQueue.main.sync { [self] () -> Bool in
                    guard self.generation == token else {
                        completion?(.failure(DisplayError.cancelled))
                        return false
                    }
                    self.isStarting = false
                    switch result {
                    case .success(let displays):
                        let ids = displays.map(\.displayID)
                        self.spatialDisplayIDs = spatial ? ids : []
                        self.currentDisplayID = ids[ids.count / 2]
                        self.isActive = true
                        completion?(.success(ids))
                    case .failure(let error):
                        self.isSpatialSession = false
                        self.lastError = error.localizedDescription
                        self.postErrorNotification(error.localizedDescription)
                        completion?(.failure(error))
                    }
                    return true
                }
                if !accepted {
                    self.retiringDisplayIDs.formUnion(self.virtualDisplays.map(\.displayID))
                    self.virtualDisplays.removeAll()
                }
            }
        }
    }

    private func createGroup(_ specifications: [Specification], arrange: Bool) throws -> [CGVirtualDisplay] {
        var displays: [CGVirtualDisplay] = []
        var succeeded = false
        defer {
            if !succeeded { retiringDisplayIDs.formUnion(displays.map(\.displayID)) }
        }
        for specification in specifications {
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.vendorID = 0x1234
            descriptor.productID = specification.product
            descriptor.serialNum = specification.serial
            descriptor.name = specification.name
            descriptor.sizeInMillimeters = specification.size
            descriptor.maxPixelsWide = specification.width
            descriptor.maxPixelsHigh = specification.height
            descriptor.queue = displayQueue
            guard let mode = CGVirtualDisplayMode(width: specification.width, height: specification.height,
                                                  refreshRate: specification.refreshRate),
                  let display = CGVirtualDisplay(descriptor: descriptor) else {
                throw DisplayError.failed("Failed to create \(specification.name).")
            }
            displays.append(display)
            let settings = CGVirtualDisplaySettings()
            settings.modes = [mode]
            guard display.apply(settings) else {
                throw DisplayError.failed("Failed to apply settings for \(specification.name).")
            }
        }
        try configureGroup(displays, specifications: specifications, arrange: arrange)
        succeeded = true
        return displays
    }

    private func configureGroup(_ displays: [CGVirtualDisplay], specifications: [Specification], arrange: Bool) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = try zip(displays, specifications).map { display, specification -> CGDisplayMode in
            var nativeMode: CGDisplayMode?
            let available = Self.waitForDisplayChange {
                let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode]
                nativeMode = modes?.first(where: { Self.matches($0, specification) })
                return nativeMode != nil
            }
            guard available, let native = nativeMode else {
                throw DisplayError.failed("Native 1× mode unavailable for \(specification.name).")
            }
            return native
        }
        let groupIDs = Set(displays.map(\.displayID))
        let existingBounds = Self.onlineDisplayIDs().filter { !groupIDs.contains($0) }.map { CGDisplayBounds($0) }
        let startX = Int32(existingBounds.map(\.maxX).max() ?? 0)
        let startY = Int32(CGDisplayBounds(CGMainDisplayID()).minY)
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            throw DisplayError.failed("Failed to begin display configuration.")
        }
        var completed = false
        defer { if !completed { CGCancelDisplayConfiguration(configuration) } }
        var offset: Int32 = 0
        for index in displays.indices {
            let id = displays[index].displayID
            guard CGConfigureDisplayWithDisplayMode(configuration, id, modes[index], nil) == .success else {
                throw DisplayError.failed("Failed to select native display mode.")
            }
            if arrange {
                guard CGConfigureDisplayMirrorOfDisplay(configuration, id, 0) == .success,
                      CGConfigureDisplayOrigin(configuration, id, startX + offset, startY) == .success else {
                    throw DisplayError.failed("Failed to arrange spatial monitors.")
                }
                offset += Int32(specifications[index].width)
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        completed = true
        guard result == .success else { throw DisplayError.failed("Failed to commit display configuration.") }
        let ready = Self.waitForDisplayChange {
            var expectedOffset: Int32 = 0
            for index in displays.indices {
                let id = displays[index].displayID
                guard let mode = CGDisplayCopyDisplayMode(id), Self.matches(mode, specifications[index]) else { return false }
                if arrange {
                    guard CGDisplayBounds(id).origin == CGPoint(x: Int(startX + expectedOffset), y: Int(startY)),
                          CGDisplayIsInMirrorSet(id) == 0 else { return false }
                    expectedOffset += Int32(specifications[index].width)
                }
            }
            return true
        }
        guard ready else {
            let actual = displays.map { "\($0.displayID): \(CGDisplayBounds($0.displayID)) mirrored=\(CGDisplayIsInMirrorSet($0.displayID))" }.joined(separator: "; ")
            throw DisplayError.failed("Spatial display configuration did not settle at x=\(startX), y=\(startY): \(actual)")
        }
    }

    /// CoreGraphics commits before WindowServer publishes its new topology.
    private static func waitForDisplayChange(_ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if ready() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return ready()
    }

    private static func matches(_ mode: CGDisplayMode, _ specification: Specification) -> Bool {
        mode.width == Int(specification.width) && mode.height == Int(specification.height) &&
        mode.pixelWidth == Int(specification.width) && mode.pixelHeight == Int(specification.height)
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func shiftDesktopOrigin(to id: CGDirectDisplayID) -> Bool {
        let ids = onlineDisplayIDs().filter { CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == 0 }
        guard ids.contains(id) else { return false }
        let origin = CGDisplayBounds(id).origin
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return false }
        for displayID in ids {
            let bounds = CGDisplayBounds(displayID)
            guard CGConfigureDisplayOrigin(configuration, displayID, Int32(bounds.minX - origin.x),
                                           Int32(bounds.minY - origin.y)) == .success else {
                CGCancelDisplayConfiguration(configuration)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success && CGMainDisplayID() == id
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isSpatialSession, self.isActive || self.isStarting else { return }
            let resolution = Settings.shared.selectedResolution
            self.disable()
            self.staticResolutionBeforeSleep = resolution
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let resolution = self.staticResolutionBeforeSleep else { return }
            self.staticResolutionBeforeSleep = nil
            let token = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.generation == token else { return }
                self.enable(resolution: resolution)
            }
        }
    }

    private func postErrorNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "UltraXReal"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
