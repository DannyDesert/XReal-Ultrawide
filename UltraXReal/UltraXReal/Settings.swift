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
        static let spatialMode = "spatialModeEnabled"
        static let sensitivity = "spatialSensitivity"
        static let smoothing = "spatialSmoothing"
        static let leanToZoom = "leanToZoomEnabled"
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

    @Published var spatialMode: Bool {
        didSet { defaults.set(spatialMode, forKey: Keys.spatialMode) }
    }

    @Published var spatialSensitivity: SpatialSensitivity {
        didSet { defaults.set(spatialSensitivity.rawValue, forKey: Keys.sensitivity) }
    }

    @Published var spatialSmoothing: SpatialSmoothing {
        didSet { defaults.set(spatialSmoothing.rawValue, forKey: Keys.smoothing) }
    }

    @Published var leanToZoomEnabled: Bool {
        didSet { defaults.set(leanToZoomEnabled, forKey: Keys.leanToZoom) }
    }

    private init() {
        let resRaw = defaults.string(forKey: Keys.resolution) ?? DisplayResolution.ultrawide2560x1080.rawValue
        self.selectedResolution = DisplayResolution(rawValue: resRaw) ?? .ultrawide2560x1080
        self.displayWasEnabled = defaults.bool(forKey: Keys.wasEnabled)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        self.spatialMode = defaults.bool(forKey: Keys.spatialMode)

        let sensRaw = defaults.string(forKey: Keys.sensitivity) ?? SpatialSensitivity.medium.rawValue
        self.spatialSensitivity = SpatialSensitivity(rawValue: sensRaw) ?? .medium

        let smoothRaw = defaults.string(forKey: Keys.smoothing) ?? SpatialSmoothing.balanced.rawValue
        self.spatialSmoothing = SpatialSmoothing(rawValue: smoothRaw) ?? .balanced

        // Default lean-to-zoom to true on first launch
        if defaults.object(forKey: Keys.leanToZoom) == nil {
            self.leanToZoomEnabled = true
        } else {
            self.leanToZoomEnabled = defaults.bool(forKey: Keys.leanToZoom)
        }
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
