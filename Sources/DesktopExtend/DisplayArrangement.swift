import CoreGraphics

enum DisplayArrangement {
    /// Places `virtualID` flush against `anchorID`, sharing its top edge.
    ///
    /// Sharing the edge for the full height matters: macOS only lets the cursor
    /// cross between displays along the overlapping span, so a misaligned
    /// origin would leave dead zones where the second desktop is unreachable.
    @discardableResult
    static func place(virtual virtualID: CGDirectDisplayID,
                      nextTo anchorID: CGDirectDisplayID,
                      side: DesktopSide) -> Bool {
        let anchor = CGDisplayBounds(anchorID)
        let virtual = CGDisplayBounds(virtualID)
        guard !anchor.isNull, !virtual.isNull else { return false }

        let x = (side == .left) ? anchor.minX - virtual.width : anchor.maxX
        let y = anchor.minY

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success,
              let config = configRef else { return false }

        guard CGConfigureDisplayOrigin(config, virtualID, Int32(x), Int32(y)) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
