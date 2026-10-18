import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let displayManager = VirtualDisplayManager()
    private let settings = Settings.shared

    // Spatial mode components
    private var imuService: XRealIMUService?
    private var spatialTracker: SpatialTracker?
    private var spatialRenderer: SpatialRenderer?
    private var isSpatialActive: Bool { sessionPhase == .running }
    private var recenterHotKeyRef: EventHotKeyRef?
    private var hotkeyEventHandler: EventHandlerRef?
    private enum SessionPhase { case idle, waitingForPermission, starting, running, stopping }
    private var sessionPhase: SessionPhase = .idle
    private var spatialRequested = false
    private var sessionGeneration = UUID()
    private var sessionError: String?
    private var shutdownCallbacks: [() -> Void] = []
    private var sleeping = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var requestedCapturePermission = false
    private var capturePermissionDenied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "UltraXReal")
            button.image?.isTemplate = true
        }

        setupRecenterHotkey()
        observeSleepWake()
        buildMenu()

        // Restore previous state
        if settings.displayWasEnabled {
            if settings.spatialMode {
                enableSpatialMode()
            } else {
                toggleStaticDisplay()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        displayManager.restoreMainDisplay()
        displayManager.restoreViewerPlacement()
        spatialRenderer?.stop()
        imuService?.stop()
        if let recenterHotKeyRef { UnregisterEventHotKey(recenterHotKeyRef) }
        if let hotkeyEventHandler { RemoveEventHandler(hotkeyEventHandler) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu(into: menu)
    }

    private func buildMenu(into existingMenu: NSMenu? = nil) {
        let menu = existingMenu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        menu.autoenablesItems = false

        // --- Mode Section ---
        // USB interfaces can briefly disappear during topology changes. Let
        // the IMU reconnect loop handle detection; do not reset HID from a menu.
        let glassesAvailable = findGlassesDisplay() != nil

        // Static mode toggle
        let staticTitle = (displayManager.isActive && !isSpatialActive) ? "Disable Ultrawide" : "Enable Ultrawide (Static)"
        let staticItem = NSMenuItem(title: staticTitle, action: #selector(toggleStaticDisplay), keyEquivalent: "e")
        staticItem.target = self
        if displayManager.isActive && !isSpatialActive {
            staticItem.state = .on
        }
        menu.addItem(staticItem)

        // Spatial mode toggle
        let spatialTitle = spatialRequested ? "Disable Floating Screens" : "Enable Floating Screens"
        let spatialItem = NSMenuItem(title: spatialTitle, action: #selector(toggleSpatialDisplay), keyEquivalent: "s")
        spatialItem.target = self
        if isSpatialActive {
            spatialItem.state = .on
        }
        if !glassesAvailable && !spatialRequested {
            spatialItem.isEnabled = false
            spatialItem.toolTip = "Connect XReal Air as an extended display to enable spatial mode."
        }
        menu.addItem(spatialItem)

        menu.addItem(NSMenuItem.separator())

        // --- Resolution submenu (for static mode) ---
        let resMenu = NSMenu()
        for resolution in DisplayResolution.allCases {
            let item = NSMenuItem(title: resolution.label, action: #selector(changeResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = resolution
            if settings.selectedResolution == resolution {
                item.state = .on
            }
            resMenu.addItem(item)
        }
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resItem.submenu = resMenu
        resItem.isEnabled = !spatialRequested && sessionPhase == .idle
        menu.addItem(resItem)

        // Mirror (static mode only)
        let mirrorItem = NSMenuItem(title: "Mirror to XReal Air", action: #selector(mirrorToXReal), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.isEnabled = displayManager.isActive && !spatialRequested && sessionPhase == .idle
        menu.addItem(mirrorItem)

        // Bring cursor onto the virtual display. In spatial mode the renderer
        // owns the glasses panel directly, so the cursor sits invisibly on the
        // built-in display by default — this menu item (and the auto-warp at
        // mode activation) gets the user clicking on the virtual content fast.
        let warpItem = NSMenuItem(title: "Move Cursor to Virtual Display",
                                  action: #selector(warpCursorToVirtualDisplay),
                                  keyEquivalent: "m")
        warpItem.keyEquivalentModifierMask = [.command, .shift]
        warpItem.target = self
        warpItem.isEnabled = displayManager.isActive
        menu.addItem(warpItem)

        menu.addItem(NSMenuItem.separator())

        // --- Spatial Settings submenu ---
        let spatialMenu = NSMenu()

        // Recenter
        let recenterItem = NSMenuItem(title: "Recenter (Cmd+Shift+R)", action: #selector(recenterSpatial), keyEquivalent: "")
        recenterItem.target = self
        recenterItem.isEnabled = isSpatialActive
        spatialMenu.addItem(recenterItem)

        let calibrationItem = NSMenuItem(title: imuService?.isCalibrating == true ? "Calibrating — Keep Glasses Still" : "Calibrate Gyroscope…",
                                         action: #selector(calibrateGyroscope), keyEquivalent: "")
        calibrationItem.target = self
        calibrationItem.isEnabled = isSpatialActive && imuService?.isConnected == true && imuService?.isCalibrating == false
        spatialMenu.addItem(calibrationItem)

        spatialMenu.addItem(NSMenuItem.separator())

        let countMenu = NSMenu()
        for count in SpatialMonitorCount.allCases {
            let item = NSMenuItem(title: "\(count.rawValue)", action: #selector(changeMonitorCount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = count.rawValue
            item.state = settings.monitorCount == count ? .on : .off
            countMenu.addItem(item)
        }
        let countItem = NSMenuItem(title: "Monitor Count", action: nil, keyEquivalent: "")
        countItem.submenu = countMenu
        spatialMenu.addItem(countItem)

        let mainMenu = NSMenu()
        for index in -1..<settings.monitorCount.rawValue {
            let title = index == -1 ? "Original Display" : settings.monitorCount.names[index]
            let item = NSMenuItem(title: title, action: #selector(changeMainMonitor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = settings.mainMonitorIndex == index ? .on : .off
            mainMenu.addItem(item)
        }
        let mainItem = NSMenuItem(title: "Main Display", action: nil, keyEquivalent: "")
        mainItem.submenu = mainMenu
        spatialMenu.addItem(mainItem)

        // Screen size + distance sliders (TV-style, live while wearing)
        let sizeSliderItem = NSMenuItem()
        sizeSliderItem.view = SliderMenuItemView(
            title: "Screen Size",
            min: 32, max: 150,
            value: settings.screenInches,
            format: { String(format: "%.0f\"", $0) },
            onChange: { [weak self] value in
                self?.settings.screenInches = value
                self?.spatialRenderer?.screenDiagonalInches = Float(value)
            }
        )
        spatialMenu.addItem(sizeSliderItem)

        let distSliderItem = NSMenuItem()
        distSliderItem.view = SliderMenuItemView(
            title: "Distance",
            min: 1.0, max: 4.0,
            value: settings.screenDistance,
            format: { String(format: "%.1fm", $0) },
            onChange: { [weak self] value in
                self?.settings.screenDistance = value
                self?.spatialRenderer?.screenDistanceMeters = Float(value)
            }
        )
        spatialMenu.addItem(distSliderItem)

        let angleSliderItem = NSMenuItem()
        angleSliderItem.view = SliderMenuItemView(
            title: "Monitor Angle",
            min: 0, max: 75,
            value: settings.monitorAngleDegrees,
            format: { String(format: "%.0f°", $0) },
            onChange: { [weak self] value in
                self?.settings.monitorAngleDegrees = value
                self?.spatialRenderer?.monitorAngleDegrees = Float(value)
            }
        )
        angleSliderItem.view?.toolTip = "Inward angle between adjacent monitors. Zero makes a flat row."
        spatialMenu.addItem(angleSliderItem)

        let gapSliderItem = NSMenuItem()
        gapSliderItem.view = SliderMenuItemView(
            title: "Monitor Gap",
            min: 0, max: 1,
            value: settings.monitorGapMeters,
            format: { String(format: "%.1f cm", $0 * 100) },
            onChange: { [weak self] value in
                self?.settings.monitorGapMeters = value
                self?.spatialRenderer?.monitorGapMeters = Float(value)
            }
        )
        spatialMenu.addItem(gapSliderItem)

        spatialMenu.addItem(NSMenuItem.separator())

        // Floating monitor resolution
        let spatialResMenu = NSMenu()
        for res in SpatialResolution.allCases {
            let item = NSMenuItem(title: res.label, action: #selector(changeSpatialResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = res.rawValue
            if settings.spatialResolution == res { item.state = .on }
            spatialResMenu.addItem(item)
        }
        let spatialResItem = NSMenuItem(title: "Monitor Resolution", action: nil, keyEquivalent: "")
        spatialResItem.submenu = spatialResMenu
        spatialMenu.addItem(spatialResItem)

        // Smoothing
        let smoothMenu = NSMenu()
        for smooth in SpatialSmoothing.allCases {
            let item = NSMenuItem(title: smooth.rawValue.capitalized, action: #selector(changeSmoothing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = smooth.rawValue
            if settings.spatialSmoothing == smooth { item.state = .on }
            smoothMenu.addItem(item)
        }
        let smoothItem = NSMenuItem(title: "Smoothing", action: nil, keyEquivalent: "")
        smoothItem.submenu = smoothMenu
        spatialMenu.addItem(smoothItem)

        // Lean-to-Zoom toggle
        let zoomItem = NSMenuItem(title: "Lean-to-Zoom", action: #selector(toggleLeanToZoom(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.state = settings.leanToZoomEnabled ? .on : .off
        spatialMenu.addItem(zoomItem)

        // Follow mode toggle: screen chases and recenters on the gaze
        let followItem = NSMenuItem(title: "Follow My View", action: #selector(toggleFollowMode(_:)), keyEquivalent: "")
        followItem.target = self
        followItem.state = settings.followModeEnabled ? .on : .off
        spatialMenu.addItem(followItem)

        let spatialSettingsItem = NSMenuItem(title: "Spatial Settings", action: nil, keyEquivalent: "")
        spatialSettingsItem.submenu = spatialMenu
        menu.addItem(spatialSettingsItem)

        menu.addItem(NSMenuItem.separator())

        // --- General Settings ---
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // --- Status info ---
        if sessionPhase == .waitingForPermission {
            let item = NSMenuItem(title: "Waiting for Screen Recording permission…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let retry = NSMenuItem(title: "Retry After Approving Recording", action: #selector(retryCapturePermission), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
            menu.addItem(NSMenuItem.separator())
        } else if isSpatialActive, let renderer = spatialRenderer {
            let fpsItem = NSMenuItem(title: "Spatial: Active (\(renderer.fps) fps)", action: nil, keyEquivalent: "")
            fpsItem.isEnabled = false
            menu.addItem(fpsItem)

            if let id = displayManager.currentDisplayID {
                let res = settings.spatialResolution
                let canvasItem = NSMenuItem(title: "\(displayManager.spatialDisplayIDs.count) monitors: \(res.width)×\(res.height) (center ID: \(id))", action: nil, keyEquivalent: "")
                canvasItem.isEnabled = false
                menu.addItem(canvasItem)
            }

            let imuItem = NSMenuItem(title: "IMU: \(imuService?.isConnected == true ? "Connected" : "Disconnected")", action: nil, keyEquivalent: "")
            imuItem.isEnabled = false
            menu.addItem(imuItem)

            menu.addItem(NSMenuItem.separator())
        } else if displayManager.isActive, let id = displayManager.currentDisplayID {
            let infoItem = NSMenuItem(title: "Display ID: \(id) — \(settings.selectedResolution.label)", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)
            menu.addItem(NSMenuItem.separator())
        }

        if let error = sessionError ?? displayManager.lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        if !displayManager.isActive {
            let tipItem = NSMenuItem(title: glassesAvailable ? "XReal display detected" : "Connect XReal Air as an extended display", action: nil, keyEquivalent: "")
            tipItem.isEnabled = false
            menu.addItem(tipItem)
            menu.addItem(NSMenuItem.separator())
        }

        // About
        let aboutItem = NSMenuItem(title: "About UltraXReal", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Session lifecycle

    @objc private func toggleStaticDisplay() {
        if spatialRequested || sessionPhase != .idle {
            disableSpatialMode { [weak self] in self?.enableStaticDisplay() }
        } else if displayManager.isActive {
            displayManager.disable()
            settings.displayWasEnabled = false
            settings.spatialMode = false
            updateIcon()
            buildMenu()
        } else {
            enableStaticDisplay()
        }
    }

    private func enableStaticDisplay() {
        guard sessionPhase == .idle, !spatialRequested else { return }
        displayManager.enable(resolution: settings.selectedResolution)
        settings.displayWasEnabled = true
        settings.spatialMode = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.spatialRequested, self.sessionPhase == .idle else { return }
            self.autoMirrorToXReal()
            self.updateIcon()
            self.buildMenu()
        }
    }

    private func autoMirrorToXReal() {
        guard !spatialRequested, let virtualID = displayManager.currentDisplayID,
              let outputID = findGlassesDisplay() else { return }
        if !DisplayMirrorHelper.mirror(virtualDisplayID: virtualID, onto: outputID) {
            sessionError = "Could not mirror the static display to XReal Air."
        }
    }

    @objc private func toggleSpatialDisplay() {
        if spatialRequested { disableSpatialMode() } else { enableSpatialMode() }
    }

    private func enableSpatialMode() {
        spatialRequested = true
        settings.displayWasEnabled = true
        settings.spatialMode = true
        startSpatialSessionIfPossible()
    }

    private func startSpatialSessionIfPossible() {
        guard spatialRequested, !sleeping, sessionPhase == .idle else { return }
        guard CGPreflightScreenCaptureAccess(), !capturePermissionDenied else {
            waitForCapturePermission()
            return
        }
        guard let outputID = findGlassesDisplay() else {
            failSpatialSession("Connect XReal Air as an extended display before enabling floating screens.")
            return
        }
        sessionPhase = .starting
        sessionError = nil
        let token = UUID()
        sessionGeneration = token
        // Resolve glasses before creating 1080p virtual monitors.
        if CGDisplayIsInMirrorSet(outputID) != 0 {
            _ = DisplayMirrorHelper.unmirror(displayID: outputID)
        }
        // Drain even an unpublished static startup before reusing display serials.
        displayManager.disable { [weak self] in
            guard let self, self.sessionGeneration == token else { return }
            self.createSpatialSession(outputID: outputID, token: token)
        }
        buildMenu()
    }

    private func createSpatialSession(outputID: CGDirectDisplayID, token: UUID) {
        let resolution = settings.spatialResolution
        displayManager.enableSpatialMonitors(count: settings.monitorCount.rawValue,
                                             width: resolution.width, height: resolution.height) { [weak self] result in
            guard let self, self.sessionGeneration == token, self.spatialRequested else { return }
            switch result {
            case .failure(let error):
                self.failSpatialSession(error.localizedDescription)
            case .success(let ids):
                guard CGDisplayIsInMirrorSet(outputID) == 0 || DisplayMirrorHelper.unmirror(displayID: outputID) else {
                    self.failSpatialSession("Could not extend the glasses display.")
                    return
                }
                let imu = XRealIMUService()
                let tracker = SpatialTracker(imuService: imu)
                tracker.smoothing = self.settings.spatialSmoothing
                tracker.leanToZoomEnabled = self.settings.leanToZoomEnabled
                tracker.followModeEnabled = self.settings.followModeEnabled
                self.imuService = imu
                self.spatialTracker = tracker
                let renderer = SpatialRenderer(virtualDisplayIDs: ids, outputDisplayID: outputID,
                                               spatialTracker: tracker, canvasWidth: Int(resolution.width),
                                               canvasHeight: Int(resolution.height))
                renderer.screenDiagonalInches = Float(self.settings.screenInches)
                renderer.screenDistanceMeters = Float(self.settings.screenDistance)
                renderer.monitorAngleDegrees = Float(self.settings.monitorAngleDegrees)
                renderer.monitorGapMeters = Float(self.settings.monitorGapMeters)
                renderer.onFailure = { [weak self] error in
                    guard let self, self.sessionGeneration == token else { return }
                    self.handleCaptureFailure(error)
                }
                self.spatialRenderer = renderer
                imu.start()
                renderer.start { [weak self] result in
                    guard let self, self.sessionGeneration == token, self.spatialRequested else { return }
                    switch result {
                    case .success:
                        guard self.displayManager.routeSpatialDesktop(viewerID: outputID) else {
                            self.failSpatialSession("Could not keep the glasses viewer outside the desktop pointer path.")
                            return
                        }
                        self.sessionPhase = .running
                        self.applyMainMonitor()
                        self.warpCursorToVirtualDisplay()
                        self.updateIcon()
                        self.buildMenu()
                    case .failure(let error):
                        self.handleCaptureFailure(error)
                    }
                }
            }
        }
    }

    private func waitForCapturePermission() {
        sessionPhase = .waitingForPermission
        sessionError = nil
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.spatialRequested, self.sessionPhase == .waitingForPermission else {
                timer.invalidate()
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                self.capturePermissionDenied = false
                return
            }
            guard !self.capturePermissionDenied else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.sessionPhase = .idle
            self.startSpatialSessionIfPossible()
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        buildMenu()
        if !requestedCapturePermission {
            requestedCapturePermission = true
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
            capturePermissionDenied = true
        }
        if capturePermissionDenied || !CGPreflightScreenCaptureAccess() {
            // Keep the user's requested session across TCC approval/relaunch.
            stopSpatialSession()
        } else {
            failSpatialSession(error.localizedDescription)
        }
    }

    @objc private func retryCapturePermission() {
        guard spatialRequested, sessionPhase == .waitingForPermission else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        capturePermissionDenied = false
        sessionPhase = .idle
        startSpatialSessionIfPossible()
    }

    private func failSpatialSession(_ message: String) {
        NSLog("Spatial session failed: %@", message)
        sessionError = message
        disableSpatialMode()
    }

    private func disableSpatialMode(completion: (() -> Void)? = nil) {
        spatialRequested = false
        settings.displayWasEnabled = false
        settings.spatialMode = false
        stopSpatialSession(completion: completion)
    }

    private func stopSpatialSession(completion: (() -> Void)? = nil) {
        if let completion { shutdownCallbacks.append(completion) }
        guard sessionPhase != .stopping else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        sessionPhase = .stopping
        sessionGeneration = UUID()
        let oldRenderer = spatialRenderer
        let oldIMU = imuService
        spatialRenderer = nil
        spatialTracker = nil
        imuService = nil
        oldRenderer?.onFailure = nil
        let finish: () -> Void = { [weak self] in
            oldIMU?.stop()
            guard let self else { return }
            self.displayManager.disable { [weak self] in
                guard let self else { return }
                self.sessionPhase = .idle
                let callbacks = self.shutdownCallbacks
                self.shutdownCallbacks.removeAll()
                self.updateIcon()
                self.buildMenu()
                callbacks.forEach { $0() }
                self.startSpatialSessionIfPossible()
            }
        }
        if let oldRenderer { oldRenderer.stop(completion: finish) } else { finish() }
        updateIcon()
        buildMenu()
    }

    private func restartSpatialSession() {
        if spatialRequested { stopSpatialSession() } else { buildMenu() }
    }

    private func applyMainMonitor() {
        guard sessionPhase == .running else { return }
        let index = settings.mainMonitorIndex
        if index == -1 {
            displayManager.restoreMainDisplay()
        } else if displayManager.spatialDisplayIDs.indices.contains(index) {
            if !displayManager.makeMainDisplay(displayManager.spatialDisplayIDs[index]) {
                sessionError = "Could not change the main display."
            }
        }
    }

    private func findGlassesDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        let external = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != 0x1234
        }
        if let known = external.first(where: { [13895, 10462, 7531].contains(CGDisplayVendorNumber($0)) }) {
            return known
        }
        let candidates = external.filter { CGDisplayPixelsWide($0) == 1920 && CGDisplayPixelsHigh($0) == 1080 }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true
            if self.spatialRequested { self.stopSpatialSession() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false
            self.startSpatialSessionIfPossible()
        })
    }

    @objc private func recenterSpatial() {
        spatialTracker?.recenter()
    }

    @objc private func calibrateGyroscope() {
        guard isSpatialActive, let imu = imuService, !imu.isCalibrating else { return }
        let prompt = NSAlert()
        prompt.messageText = "Calibrate Gyroscope"
        prompt.informativeText = "Rest the glasses on a stable surface. Keep them completely still for two seconds after starting. The correction is saved for these glasses."
        prompt.addButton(withTitle: "Start Calibration")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        imu.calibrateGyroscope { [weak self, weak imu] error in
            guard let self, let imu, self.imuService === imu else { return }
            self.buildMenu()
            let result = NSAlert()
            result.messageText = error == nil ? "Gyroscope Calibrated" : "Calibration Failed"
            result.informativeText = error ?? "Put the glasses back on, face forward, then press Cmd+Shift+R to recenter. Recalibrate if drift returns as the glasses warm up."
            result.runModal()
        }
        buildMenu()
    }

    // MARK: - Spatial Settings Actions

    @objc private func changeSpatialResolution(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let resolution = SpatialResolution(rawValue: raw),
              resolution != settings.spatialResolution else { return }
        settings.spatialResolution = resolution
        restartSpatialSession()
    }

    @objc private func changeMonitorCount(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let count = SpatialMonitorCount(rawValue: raw),
              count != settings.monitorCount else { return }
        let oldNames = settings.monitorCount.names
        let oldMainName = oldNames.indices.contains(settings.mainMonitorIndex) ? oldNames[settings.mainMonitorIndex] : nil
        settings.monitorCount = count
        settings.mainMonitorIndex = oldMainName.flatMap { count.names.firstIndex(of: $0) } ?? -1
        restartSpatialSession()
    }

    @objc private func changeMainMonitor(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              (-1..<settings.monitorCount.rawValue).contains(index) else { return }
        settings.mainMonitorIndex = index
        applyMainMonitor()
        buildMenu()
    }

    @objc private func changeSmoothing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let smooth = SpatialSmoothing(rawValue: raw) else { return }
        settings.spatialSmoothing = smooth
        spatialTracker?.smoothing = smooth
        buildMenu()
    }

    @objc private func toggleLeanToZoom(_ sender: NSMenuItem) {
        settings.leanToZoomEnabled.toggle()
        spatialTracker?.leanToZoomEnabled = settings.leanToZoomEnabled
        buildMenu()
    }

    @objc private func toggleFollowMode(_ sender: NSMenuItem) {
        settings.followModeEnabled.toggle()
        spatialTracker?.followModeEnabled = settings.followModeEnabled
        buildMenu()
    }


    // MARK: - Shared Actions

    @objc private func changeResolution(_ sender: NSMenuItem) {
        guard let resolution = sender.representedObject as? DisplayResolution else { return }
        settings.selectedResolution = resolution
        if displayManager.isActive && !isSpatialActive {
            displayManager.changeResolution(resolution)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.buildMenu()
        }
    }

    @objc private func mirrorToXReal() {
        autoMirrorToXReal()
    }

    /// Teleport the mouse cursor to the centre of the active virtual display.
    /// Spatial mode renders directly onto the glasses panel and unmirrors the
    /// XReal Air, so the cursor stays on the built-in display by default —
    /// invisible to the user. This action (called automatically when entering
    /// spatial, and bound to ⌘⇧M) puts the cursor where the user is looking.
    @objc private func warpCursorToVirtualDisplay() {
        guard let vid = displayManager.currentDisplayID else { return }
        let bounds = CGDisplayBounds(vid)
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        settings.launchAtLogin.toggle()
        sender.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "UltraXReal",
            .applicationVersion: "2.0.0",
            .credits: NSAttributedString(
                string: "Open-source spatial display for XReal Air glasses.\nStatic ultrawide + head-tracked floating display.\nhttps://github.com/DannyDesert/XReal-Ultrawide",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        disableSpatialMode {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Global Hotkey

    private func setupRecenterHotkey() {
        // Carbon hotkey: fires system-wide without the Accessibility/Input
        // Monitoring permission that NSEvent global monitors silently require.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.recenterSpatial() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotkeyEventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5558_5252), id: 1) // 'UXRR'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &recenterHotKeyRef)
    }

    // MARK: - Icon

    private func updateIcon() {
        if let button = statusItem.button {
            if isSpatialActive {
                let image = NSImage(systemSymbolName: "view.3d", accessibilityDescription: "UltraXReal Spatial")
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemCyan])
                button.image = image?.withSymbolConfiguration(config)
            } else if displayManager.isActive {
                let image = NSImage(systemSymbolName: "display", accessibilityDescription: "UltraXReal Active")
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
                button.image = image?.withSymbolConfiguration(config)
            } else {
                button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "UltraXReal")
                button.image?.isTemplate = true
            }
        }
    }
}

// MARK: - SliderMenuItemView

/// A menu item hosting a live slider with a title and value readout.
/// Custom-view items don't close the menu on interaction, so the user can
/// drag while watching the effect through the glasses.
final class SliderMenuItemView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let format: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String,
         min: Double, max: Double, value: Double,
         format: @escaping (Double) -> String,
         onChange: @escaping (Double) -> Void) {
        self.format = format
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 48))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 14, y: 26, width: 150, height: 17)
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 160, y: 26, width: 86, height: 17)
        valueLabel.stringValue = format(value)
        addSubview(valueLabel)

        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid(_:))
        slider.frame = NSRect(x: 14, y: 4, width: 232, height: 20)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func slid(_ sender: NSSlider) {
        valueLabel.stringValue = format(sender.doubleValue)
        onChange(sender.doubleValue)
    }
}
