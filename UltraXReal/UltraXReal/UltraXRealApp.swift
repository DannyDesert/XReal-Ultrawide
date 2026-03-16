import SwiftUI

@main
struct UltraXRealApp: App {
    @StateObject private var displayManager = VirtualDisplayManager()
    private let settings = Settings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(displayManager: displayManager, settings: settings)
                .onAppear {
                    restorePreviousState()
                }
        } label: {
            Image(systemName: "display")
                .symbolRenderingMode(.palette)
                .foregroundStyle(displayManager.isActive ? .green : .gray)
        }
    }

    private func restorePreviousState() {
        if settings.displayWasEnabled && !displayManager.isActive {
            displayManager.enable(resolution: settings.selectedResolution)
        }
    }
}
