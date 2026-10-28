import AppKit
import ScreenCaptureKit

/// The agent's screenshot: one display, scaled to the mapping's image size, with every
/// LocalFlow window left out (the host app shares this bundle id).
enum ComputerScreenshot {
    static let jpegQuality = 0.85

    static func captureJPEG(displayID: CGDirectDisplayID, size: CGSize) async throws -> Data {
        let image: CGImage
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ComputerError("The display this agent controls isn't available to capture.")
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps(in: content),
                                         exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            configuration.showsCursor = true
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let error as ComputerError {
            throw error
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw ComputerError("LocalFlow needs Screen Recording permission to take screenshots "
                + "(System Settings > Privacy & Security > Screen & System Audio Recording).")
        } catch {
            throw ComputerError("Couldn't take a screenshot: \(error.localizedDescription)")
        }
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: jpegQuality]
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: properties) else {
            throw ComputerError("Couldn't encode the screenshot.")
        }
        return jpeg
    }

    /// This process and anything sharing LocalFlow's bundle id.
    private static func ownApps(in content: SCShareableContent) -> [SCRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.applications.filter { app in
            app.processID == ownPID || (ownBundleID != nil && app.bundleIdentifier == ownBundleID)
        }
    }
}
