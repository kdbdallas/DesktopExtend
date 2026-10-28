import AppKit
import CVirtualDisplay

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? kCGNullDirectDisplay
    }
}

@MainActor
final class VirtualDisplayManager {
    static var isSupported: Bool { DEVirtualDisplay.isSupported }

    private var display: DEVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID = kCGNullDirectDisplay

    var isActive: Bool { display != nil && displayID != kCGNullDirectDisplay }

    /// Creates a second display that matches `screen` exactly — same point size,
    /// same backing scale. The match is what lets the mirror land 1:1 on the
    /// panel instead of being resampled.
    func create(matching screen: NSScreen, name: String) -> Bool {
        destroy()
        let scale = UInt(screen.backingScaleFactor.rounded())
        guard let created = DEVirtualDisplay(name: name,
                                             pointSize: screen.frame.size,
                                             scale: max(scale, 1)) else {
            return false
        }
        display = created
        displayID = created.displayID
        return displayID != kCGNullDirectDisplay
    }

    /// The WindowServer registers the display asynchronously; capture started
    /// before it lands would fail to find it.
    func waitUntilReady(timeout: TimeInterval = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSScreen.screens.contains(where: { $0.displayID == displayID }),
               !CGDisplayBounds(displayID).isEmpty {
                // Let the arrangement settle before anything reads its bounds.
                try? await Task.sleep(nanoseconds: 150_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func destroy() {
        display = nil
        displayID = kCGNullDirectDisplay
    }
}
