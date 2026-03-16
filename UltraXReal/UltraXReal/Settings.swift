import Foundation
import ServiceManagement

/// Persists user preferences via UserDefaults.
final class Settings: ObservableObject {

    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let resolution = "selectedResolution"
        static let wasEnabled = "displayWasEnabled"
        static let launchAtLogin = "launchAtLogin"
    }

    @Published var selectedResolution: DisplayResolution {
        didSet {
            defaults.set(selectedResolution.rawValue, forKey: Keys.resolution)
        }
    }

    @Published var displayWasEnabled: Bool {
        didSet {
            defaults.set(displayWasEnabled, forKey: Keys.wasEnabled)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    private init() {
        let resRaw = defaults.string(forKey: Keys.resolution) ?? DisplayResolution.ultrawide2560x1080.rawValue
        self.selectedResolution = DisplayResolution(rawValue: resRaw) ?? .ultrawide2560x1080
        self.displayWasEnabled = defaults.bool(forKey: Keys.wasEnabled)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
    }

    private func updateLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }
}
