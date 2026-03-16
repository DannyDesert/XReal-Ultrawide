import SwiftUI

/// The menu bar dropdown content.
struct MenuBarView: View {
    @ObservedObject var displayManager: VirtualDisplayManager
    @ObservedObject var settings: Settings

    var body: some View {
        VStack {
            // Toggle button
            Button(displayManager.isActive ? "Disable Ultrawide" : "Enable Ultrawide") {
                if displayManager.isActive {
                    displayManager.disable()
                    settings.displayWasEnabled = false
                } else {
                    displayManager.enable(resolution: settings.selectedResolution)
                    settings.displayWasEnabled = true
                }
            }
            .keyboardShortcut("e", modifiers: .command)

            Divider()

            // Resolution submenu
            Menu("Resolution") {
                ForEach(DisplayResolution.allCases) { resolution in
                    Button {
                        settings.selectedResolution = resolution
                        if displayManager.isActive {
                            displayManager.changeResolution(resolution)
                        }
                    } label: {
                        HStack {
                            Text(resolution.label)
                            if settings.selectedResolution == resolution {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            // Mirror to XReal Air
            Button("Mirror to XReal Air") {
                guard let virtualID = displayManager.currentDisplayID else { return }
                if let xrealID = DisplayMirrorHelper.findXRealDisplay() {
                    DisplayMirrorHelper.mirror(virtualDisplayID: virtualID, onto: xrealID)
                }
            }
            .disabled(!displayManager.isActive)

            Divider()

            // Launch at Login
            Toggle("Launch at Login", isOn: $settings.launchAtLogin)

            Divider()

            // Display info when active
            if displayManager.isActive, let id = displayManager.currentDisplayID {
                Text("Display ID: \(id)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Resolution: \(settings.selectedResolution.label)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()
            }

            // Error display
            if let error = displayManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
                Divider()
            }

            // Tip
            if !displayManager.isActive {
                Text("Tip: Connect XReal Air via USB-C,\nthen enable ultrawide.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
            }

            // About
            Button("About UltraXReal") {
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

            Button("Quit") {
                displayManager.disable()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
