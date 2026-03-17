import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let displayManager = VirtualDisplayManager()
    private let settings = Settings.shared

    // Spatial mode components
    private var imuService: XRealIMUService?
    private var spatialTracker: SpatialTracker?
    private var spatialRenderer: SpatialRenderer?
    private var isSpatialActive = false
    private var globalHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "UltraXReal")
            button.image?.isTemplate = true
        }

        setupRecenterHotkey()
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
        if isSpatialActive {
            disableSpatialMode()
        }
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // --- Mode Section ---
        let imuAvailable = XRealIMUService.isDeviceAvailable()

        // Static mode toggle
        let staticTitle = (displayManager.isActive && !isSpatialActive) ? "Disable Ultrawide" : "Enable Ultrawide (Static)"
        let staticItem = NSMenuItem(title: staticTitle, action: #selector(toggleStaticDisplay), keyEquivalent: "e")
        staticItem.target = self
        if displayManager.isActive && !isSpatialActive {
            staticItem.state = .on
        }
        menu.addItem(staticItem)

        // Spatial mode toggle
        let spatialTitle = isSpatialActive ? "Disable Spatial" : "Enable Spatial (Floating)"
        let spatialItem = NSMenuItem(title: spatialTitle, action: #selector(toggleSpatialDisplay), keyEquivalent: "s")
        spatialItem.target = self
        if isSpatialActive {
            spatialItem.state = .on
        }
        if !imuAvailable && !isSpatialActive {
            spatialItem.isEnabled = false
            spatialItem.toolTip = "Connect XReal Air via USB-C to enable spatial mode (IMU not detected)"
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
        resItem.isEnabled = !isSpatialActive  // Disabled during spatial mode
        menu.addItem(resItem)

        // Mirror (static mode only)
        let mirrorItem = NSMenuItem(title: "Mirror to XReal Air", action: #selector(mirrorToXReal), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.isEnabled = displayManager.isActive && !isSpatialActive
        menu.addItem(mirrorItem)

        menu.addItem(NSMenuItem.separator())

        // --- Spatial Settings submenu ---
        let spatialMenu = NSMenu()

        // Recenter
        let recenterItem = NSMenuItem(title: "Recenter (Cmd+Shift+R)", action: #selector(recenterSpatial), keyEquivalent: "")
        recenterItem.target = self
        recenterItem.isEnabled = isSpatialActive
        spatialMenu.addItem(recenterItem)

        spatialMenu.addItem(NSMenuItem.separator())

        // Sensitivity
        let sensMenu = NSMenu()
        for sens in SpatialSensitivity.allCases {
            let item = NSMenuItem(title: sens.rawValue.capitalized, action: #selector(changeSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sens.rawValue
            if settings.spatialSensitivity == sens { item.state = .on }
            sensMenu.addItem(item)
        }
        let sensItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensItem.submenu = sensMenu
        spatialMenu.addItem(sensItem)

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
        if isSpatialActive, let renderer = spatialRenderer {
            let fpsItem = NSMenuItem(title: "Spatial: Active (\(renderer.fps) fps)", action: nil, keyEquivalent: "")
            fpsItem.isEnabled = false
            menu.addItem(fpsItem)

            if let id = displayManager.currentDisplayID {
                let canvasItem = NSMenuItem(title: "Canvas: 3840x2160 (ID: \(id))", action: nil, keyEquivalent: "")
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

        if let error = displayManager.lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        if !displayManager.isActive {
            let imuStatus = imuAvailable ? "IMU detected" : "IMU not detected"
            let tipItem = NSMenuItem(title: "Tip: Connect XReal Air via USB-C (\(imuStatus))", action: nil, keyEquivalent: "")
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

    // MARK: - Static Mode Actions

    @objc private func toggleStaticDisplay() {
        // If spatial is active, disable it first
        if isSpatialActive {
            disableSpatialMode()
        }

        if displayManager.isActive {
            if let xrealID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: displayManager.currentDisplayID) {
                DisplayMirrorHelper.unmirror(displayID: xrealID)
            }
            displayManager.disable()
            settings.displayWasEnabled = false
            settings.spatialMode = false
        } else {
            displayManager.enable(resolution: settings.selectedResolution)
            settings.displayWasEnabled = true
            settings.spatialMode = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.autoMirrorToXReal()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateIcon()
            self?.buildMenu()
        }
    }

    private func autoMirrorToXReal() {
        guard let virtualID = displayManager.currentDisplayID else { return }
        if let xrealID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: virtualID) {
            let success = DisplayMirrorHelper.mirror(virtualDisplayID: virtualID, onto: xrealID)
            if success {
                print("Auto-mirrored virtual display \(virtualID) to XReal Air \(xrealID)")
            } else {
                print("Failed to auto-mirror to XReal Air")
            }
        } else {
            print("XReal Air display not found — use Mirror to XReal Air manually")
        }
    }

    // MARK: - Spatial Mode Actions

    @objc private func toggleSpatialDisplay() {
        if isSpatialActive {
            disableSpatialMode()
        } else {
            // If static mode is active, disable it first
            if displayManager.isActive {
                if let xrealID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: displayManager.currentDisplayID) {
                    DisplayMirrorHelper.unmirror(displayID: xrealID)
                }
                displayManager.disable()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.enableSpatialMode()
                }
            } else {
                enableSpatialMode()
            }
        }
    }

    private func enableSpatialMode() {
        // 1. Create large canvas virtual display
        displayManager.enableSpatialCanvas()

        // 2. Wait for display, then set up the spatial pipeline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let virtualID = self.displayManager.currentDisplayID else {
                print("[Spatial] Failed — virtual display not created")
                return
            }

            // Unmirror XReal Air — spatial mode renders directly
            if let xrealID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: virtualID) {
                DisplayMirrorHelper.unmirror(displayID: xrealID)
            }

            // 3. Start IMU
            let imu = XRealIMUService()
            imu.start()
            self.imuService = imu

            // 4. Start spatial tracker
            let tracker = SpatialTracker(imuService: imu)
            tracker.sensitivity = self.settings.spatialSensitivity
            tracker.smoothing = self.settings.spatialSmoothing
            tracker.leanToZoomEnabled = self.settings.leanToZoomEnabled
            self.spatialTracker = tracker

            // 5. Start renderer
            let renderer = SpatialRenderer(
                virtualDisplayID: virtualID,
                spatialTracker: tracker
            )
            renderer.start()
            self.spatialRenderer = renderer

            self.isSpatialActive = true
            self.settings.displayWasEnabled = true
            self.settings.spatialMode = true

            self.updateIcon()
            self.buildMenu()

            // Auto-recenter after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                tracker.recenter()
            }
        }
    }

    private func disableSpatialMode() {
        spatialRenderer?.stop()
        spatialRenderer = nil
        spatialTracker = nil
        imuService?.stop()
        imuService = nil

        displayManager.disable()
        isSpatialActive = false
        settings.displayWasEnabled = false
        settings.spatialMode = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateIcon()
            self?.buildMenu()
        }
    }

    @objc private func recenterSpatial() {
        spatialTracker?.recenter()
    }

    // MARK: - Spatial Settings Actions

    @objc private func changeSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sens = SpatialSensitivity(rawValue: raw) else { return }
        settings.spatialSensitivity = sens
        spatialTracker?.sensitivity = sens
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
        if isSpatialActive {
            disableSpatialMode()
        } else {
            displayManager.disable()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Global Hotkey

    private func setupRecenterHotkey() {
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cmd+Shift+R (keyCode 15 = R)
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                self?.recenterSpatial()
            }
        }
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
