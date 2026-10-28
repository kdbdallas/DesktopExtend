import CoreGraphics
import Foundation

/// Reports which display the cursor is currently on.
///
/// This polls rather than installing a global event monitor, which keeps the
/// app clear of the Accessibility / Input Monitoring permission prompts — the
/// cursor position is readable without any entitlement.
final class CursorWatcher {
    /// Called on the main queue whenever the cursor lands on a different display.
    var onDisplayChange: ((CGDirectDisplayID) -> Void)?
    /// Called on the main queue with the cursor's distance, in points, from the
    /// shared edge — used to warm up a snapshot just before the crossing.
    var onApproachEdge: ((CGFloat) -> Void)?

    var anchorDisplay: CGDirectDisplayID = kCGNullDirectDisplay
    var side: DesktopSide = .left

    private let queue = DispatchQueue(label: "com.port21.DesktopExtend.cursor",
                                      qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastDisplay: CGDirectDisplayID = kCGNullDirectDisplay

    /// 120 Hz: fast enough that the transition starts on the same frame the
    /// cursor crosses, cheap enough to be invisible in Activity Monitor.
    private static let pollInterval = DispatchTimeInterval.microseconds(8_333)

    /// Only report proximity once the cursor is actually near the edge —
    /// otherwise this would hop to the main queue 120 times a second for
    /// nothing.
    private static let reportProximityWithin: CGFloat = 300

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastDisplay = kCGNullDirectDisplay
    }

    private func poll() {
        guard let location = CGEvent(source: nil)?.location else { return }

        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 8, &ids, &count) == .success, count > 0 else { return }
        let current = ids[0]

        if current != lastDisplay {
            lastDisplay = current
            DispatchQueue.main.async { self.onDisplayChange?(current) }
        }

        if current == anchorDisplay {
            let bounds = CGDisplayBounds(anchorDisplay)
            let distance = (side == .left) ? location.x - bounds.minX : bounds.maxX - location.x
            if distance < Self.reportProximityWithin {
                DispatchQueue.main.async { self.onApproachEdge?(distance) }
            }
        }
    }
}
