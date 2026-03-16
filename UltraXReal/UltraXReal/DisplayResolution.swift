import Foundation
import CoreGraphics

/// Supported virtual display resolutions.
enum DisplayResolution: String, CaseIterable, Identifiable, Codable {
    case ultrawide2560x1080 = "2560x1080"
    case ultrawideHiDPI3440x1440 = "3440x1440"
    case superUltrawide3840x1080 = "3840x1080"

    var id: String { rawValue }

    var width: UInt32 {
        switch self {
        case .ultrawide2560x1080: return 2560
        case .ultrawideHiDPI3440x1440: return 3440
        case .superUltrawide3840x1080: return 3840
        }
    }

    var height: UInt32 {
        switch self {
        case .ultrawide2560x1080: return 1080
        case .ultrawideHiDPI3440x1440: return 1440
        case .superUltrawide3840x1080: return 1080
        }
    }

    var label: String {
        switch self {
        case .ultrawide2560x1080: return "2560 × 1080 (21:9)"
        case .ultrawideHiDPI3440x1440: return "3440 × 1440 (21:9 HiDPI)"
        case .superUltrawide3840x1080: return "3840 × 1080 (32:9)"
        }
    }

    /// Physical size in millimeters for correct DPI calculation.
    /// Based on equivalent real-world monitor dimensions.
    var sizeInMillimeters: CGSize {
        switch self {
        case .ultrawide2560x1080:
            // ~25" ultrawide equivalent
            return CGSize(width: 597, height: 252)
        case .ultrawideHiDPI3440x1440:
            // ~34" ultrawide equivalent
            return CGSize(width: 800, height: 335)
        case .superUltrawide3840x1080:
            // ~43" super ultrawide equivalent
            return CGSize(width: 1052, height: 296)
        }
    }

    var refreshRate: Double { 60.0 }
}
