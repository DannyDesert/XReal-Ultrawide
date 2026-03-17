import CoreGraphics
import Foundation

/// Helpers for display mirroring using CoreGraphics configuration APIs.
///
/// Attempts to mirror the virtual display onto the XReal Air's physical panel.
/// Falls back gracefully if mirroring cannot be automated.
enum DisplayMirrorHelper {

    // Known XReal/Nreal vendor IDs (USB vendor ID space)
    private static let xrealVendorIDs: Set<UInt32> = [
        13895, // 0x3647 — XReal Air (observed)
        10462, // 0x28DE — alternate
        7531,  // 0x1D6B — alternate
    ]

    /// Attempts to find the XReal Air display among online displays.
    /// Uses vendor ID matching first, falls back to 1920×1080 non-builtin heuristic.
    static func findXRealDisplay(excludingDisplayID: CGDirectDisplayID? = nil) -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(16, &displayIDs, &displayCount)
        guard err == .success else { return nil }

        // First pass: match by vendor ID
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if id == excludingDisplayID { continue }
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let vendor = CGDisplayVendorNumber(id)
            if xrealVendorIDs.contains(vendor) {
                return id
            }
        }

        // Second pass: fall back to first external 1920×1080 display
        // that isn't our virtual display or the built-in
        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if id == excludingDisplayID { continue }
            if CGDisplayIsBuiltin(id) != 0 { continue }

            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            if width == 1920 && height == 1080 {
                return id
            }
        }

        return nil
    }

    /// Mirror the virtual display onto the target physical display.
    @discardableResult
    static func mirror(virtualDisplayID: CGDirectDisplayID, onto targetDisplayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&config) == .success,
              let config else {
            return false
        }

        let mirrorErr = CGConfigureDisplayMirrorOfDisplay(config, targetDisplayID, virtualDisplayID)
        guard mirrorErr == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        return completeErr == .success
    }

    /// Remove mirroring from a display.
    @discardableResult
    static func unmirror(displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&config) == .success,
              let config else {
            return false
        }

        let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

private let kCGNullDirectDisplay: CGDirectDisplayID = 0
