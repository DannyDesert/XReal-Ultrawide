import CoreGraphics
import Foundation

/// Helpers for display mirroring using CoreGraphics configuration APIs.
///
/// Attempts to mirror the virtual display onto the XReal Air's physical panel.
/// Falls back gracefully if mirroring cannot be automated.
enum DisplayMirrorHelper {

    /// Attempts to find the XReal Air display among online displays.
    /// XReal Air typically identifies as a 1920×1080 display via USB-C DisplayPort.
    static func findXRealDisplay() -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(16, &displayIDs, &displayCount)
        guard err == .success else { return nil }

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)

            // XReal Air presents as 1920x1080 — skip the built-in display
            // and any virtual displays we created
            // CGDisplayIsBuiltin returns boolean_t (UInt32), not Bool
            if width == 1920 && height == 1080 && CGDisplayIsBuiltin(id) == 0 {
                return id
            }
        }
        return nil
    }

    /// Mirror the virtual display onto the target physical display.
    ///
    /// - Parameters:
    ///   - virtualDisplayID: The CGDirectDisplayID of our virtual display
    ///   - targetDisplayID: The CGDirectDisplayID of the XReal Air
    /// - Returns: true if mirroring was configured successfully
    @discardableResult
    static func mirror(virtualDisplayID: CGDirectDisplayID, onto targetDisplayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?

        guard CGBeginDisplayConfiguration(&config) == .success,
              let config else {
            return false
        }

        // Configure the target (XReal Air) to mirror the virtual display
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

        // Setting mirror to kCGNullDirectDisplay removes mirroring
        let err = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

/// CGDirectDisplayID constant for "no display"
private let kCGNullDirectDisplay: CGDirectDisplayID = 0
