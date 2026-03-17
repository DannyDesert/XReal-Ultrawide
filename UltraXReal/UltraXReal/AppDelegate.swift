import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let displayManager = VirtualDisplayManager()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "UltraXReal")
            button.image?.isTemplate = true
        }

        buildMenu()

        // Restore previous state
        if settings.displayWasEnabled {
            toggleDisplay()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Toggle
        let toggleTitle = displayManager.isActive ? "Disable Ultrawide" : "Enable Ultrawide"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleDisplay), keyEquivalent: "e")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Resolution submenu
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
        menu.addItem(resItem)

        // Mirror
        let mirrorItem = NSMenuItem(title: "Mirror to XReal Air", action: #selector(mirrorToXReal), keyEquivalent: "")
        mirrorItem.target = self
        mirrorItem.isEnabled = displayManager.isActive
        menu.addItem(mirrorItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // Status info
        if displayManager.isActive, let id = displayManager.currentDisplayID {
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
            let tipItem = NSMenuItem(title: "Tip: Connect XReal Air via USB-C, then enable", action: nil, keyEquivalent: "")
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

    // MARK: - Actions

    @objc private func toggleDisplay() {
        if displayManager.isActive {
            // Unmirror the Air before disabling
            if let xrealID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: displayManager.currentDisplayID) {
                DisplayMirrorHelper.unmirror(displayID: xrealID)
            }
            displayManager.disable()
            settings.displayWasEnabled = false
        } else {
            displayManager.enable(resolution: settings.selectedResolution)
            settings.displayWasEnabled = true

            // Auto-mirror to XReal Air after display is created
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.autoMirrorToXReal()
            }
        }

        // Update icon tint
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

    @objc private func changeResolution(_ sender: NSMenuItem) {
        guard let resolution = sender.representedObject as? DisplayResolution else { return }
        settings.selectedResolution = resolution
        if displayManager.isActive {
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
            .applicationVersion: "1.0.0",
            .credits: NSAttributedString(
                string: "Open-source ultrawide virtual display for XReal Air glasses.\nhttps://github.com/DannyDesert/XReal-Ultrawide",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        displayManager.disable()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func updateIcon() {
        if let button = statusItem.button {
            if displayManager.isActive {
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
