import Foundation
import ServiceManagement

/// Resolution of the floating virtual monitor.
enum SpatialResolution: String, CaseIterable, Codable {
    case fhd1080, qhd1440

    var width: UInt32 {
        switch self {
        case .fhd1080: return 1920
        case .qhd1440: return 2560
        }
    }

    var height: UInt32 {
        switch self {
        case .fhd1080: return 1080
        case .qhd1440: return 1440
        }
    }

    var label: String {
        switch self {
        case .fhd1080: return "1920×1080 (sharpest text)"
        case .qhd1440: return "2560×1440 (more space)"
        }
    }
}

/// Persists user preferences via UserDefaults.
final class Settings: ObservableObject {

    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let resolution = "selectedResolution"
        static let wasEnabled = "displayWasEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let spatialMode = "spatialModeEnabled"
        static let smoothing = "spatialSmoothing"
        static let leanToZoom = "leanToZoomEnabled"
        static let screenInches = "floatingScreenInches"
        static let screenDistance = "floatingScreenDistance"
        static let spatialResolution = "spatialResolution"
        static let followMode = "followModeEnabled"
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

    @Published var spatialSmoothing: SpatialSmoothing {
        didSet { defaults.set(spatialSmoothing.rawValue, forKey: Keys.smoothing) }
    }

    @Published var leanToZoomEnabled: Bool {
        didSet { defaults.set(leanToZoomEnabled, forKey: Keys.leanToZoom) }
    }

    @Published var screenInches: Double {
        didSet { defaults.set(screenInches, forKey: Keys.screenInches) }
    }

    @Published var screenDistance: Double {
        didSet { defaults.set(screenDistance, forKey: Keys.screenDistance) }
    }

    @Published var spatialResolution: SpatialResolution {
        didSet { defaults.set(spatialResolution.rawValue, forKey: Keys.spatialResolution) }
    }

    @Published var followModeEnabled: Bool {
        didSet { defaults.set(followModeEnabled, forKey: Keys.followMode) }
    }

    private init() {
        let resRaw = defaults.string(forKey: Keys.resolution) ?? DisplayResolution.ultrawide2560x1080.rawValue
        self.selectedResolution = DisplayResolution(rawValue: resRaw) ?? .ultrawide2560x1080
        self.displayWasEnabled = defaults.bool(forKey: Keys.wasEnabled)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)

        self.spatialMode = defaults.bool(forKey: Keys.spatialMode)

        let smoothRaw = defaults.string(forKey: Keys.smoothing) ?? SpatialSmoothing.balanced.rawValue
        self.spatialSmoothing = SpatialSmoothing(rawValue: smoothRaw) ?? .balanced

        let inches = defaults.double(forKey: Keys.screenInches)
        self.screenInches = inches > 0 ? inches : 65

        let dist = defaults.double(forKey: Keys.screenDistance)
        self.screenDistance = dist > 0 ? dist : 2.0

        let resRawSpatial = defaults.string(forKey: Keys.spatialResolution) ?? SpatialResolution.fhd1080.rawValue
        self.spatialResolution = SpatialResolution(rawValue: resRawSpatial) ?? .fhd1080

        self.followModeEnabled = defaults.bool(forKey: Keys.followMode)

        // On by default: the lean gesture is impulse-based, so it no longer
        // fires from just looking up.
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
