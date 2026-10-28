import AppKit
import ScreenCaptureKit

/// A click-through window that never takes focus. It sits above everything —
/// including the menu bar and full-screen apps — so the mirrored desktop reads
/// as the real thing rather than as a window floating over it.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay window and drives the slide between the two desktops.
///
/// The window hosts a container layer twice the width of the panel, holding the
/// live mirror in one half and a still of the physical desktop in the other.
/// Sliding that container is what produces the "scroll across" effect — the
/// physical desktop cannot actually move, so it is stood in for by the still.
@MainActor
final class OverlayController {
    private let window: OverlayWindow
    private let container = CALayer()
    private let snapshotLayer = CALayer()
    private let mirror: MirrorRenderer

    private var panelSize: CGSize
    private var scale: CGFloat
    private var side: DesktopSide

    private(set) var isShowingVirtual = false
    private var snapshotCapturedAt: CFTimeInterval = 0
    private var snapshotTask: Task<Void, Never>?

    init(mirror: MirrorRenderer, screenFrame: CGRect, scale: CGFloat, side: DesktopSide) {
        self.mirror = mirror
        self.panelSize = screenFrame.size
        self.scale = scale
        self.side = side

        window = OverlayWindow(contentRect: screenFrame,
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        // Keep the overlay out of every screen capture — including the still we
        // take of the physical desktop, which would otherwise recurse.
        window.sharingType = .none

        let host = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        window.contentView = host

        snapshotLayer.anchorPoint = .zero
        snapshotLayer.contentsGravity = .resize
        snapshotLayer.contentsScale = scale
        snapshotLayer.isOpaque = true

        container.anchorPoint = .zero
        container.masksToBounds = false
        host.layer?.addSublayer(container)
        container.addSublayer(mirror.layer)
        container.addSublayer(snapshotLayer)

        layoutLayers()
        moveContainer(to: physicalOffset, animated: false)
    }

    // MARK: - Geometry

    /// Container-x when the physical desktop fills the panel.
    private var physicalOffset: CGFloat { side == .left ? -panelSize.width : 0 }
    /// Container-x when the second desktop fills the panel.
    private var virtualOffset: CGFloat { side == .left ? 0 : -panelSize.width }

    private func layoutLayers() {
        let width = panelSize.width
        let height = panelSize.height
        container.bounds = CGRect(x: 0, y: 0, width: width * 2, height: height)

        // The two halves are ordered so that sliding the container in the
        // direction the cursor travelled reveals the right desktop.
        let mirrorX: CGFloat = (side == .left) ? 0 : width
        let snapshotX: CGFloat = (side == .left) ? width : 0
        mirror.layer.frame = CGRect(x: mirrorX, y: 0, width: width, height: height)
        snapshotLayer.frame = CGRect(x: snapshotX, y: 0, width: width, height: height)
    }

    func update(screenFrame: CGRect, scale: CGFloat, side: DesktopSide) {
        self.panelSize = screenFrame.size
        self.scale = scale
        self.side = side
        snapshotLayer.contentsScale = scale
        window.setFrame(screenFrame, display: false)
        window.contentView?.frame = CGRect(origin: .zero, size: screenFrame.size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        container.position = CGPoint(x: isShowingVirtual ? virtualOffset : physicalOffset, y: 0)
        CATransaction.commit()
    }

    // MARK: - Transitions

    func showVirtualDesktop(animated: Bool = true) {
        guard !isShowingVirtual else { return }
        isShowingVirtual = true

        // With no still available the physical half stays transparent, so the
        // real desktop shows through and the mirror simply slides over it.
        snapshotLayer.isHidden = !Settings.shared.usePushTransition || snapshotLayer.contents == nil

        moveContainer(to: physicalOffset, animated: false)
        window.orderFrontRegardless()
        moveContainer(to: virtualOffset, animated: animated)
    }

    func showPhysicalDesktop(animated: Bool = true) {
        guard isShowingVirtual else { return }
        isShowingVirtual = false

        moveContainer(to: physicalOffset, animated: animated) { [weak self] in
            guard let self, !self.isShowingVirtual else { return }
            self.window.orderOut(nil)
        }
    }

    func hideImmediately() {
        isShowingVirtual = false
        moveContainer(to: physicalOffset, animated: false)
        window.orderOut(nil)
    }

    private func moveContainer(to x: CGFloat,
                               animated: Bool,
                               completion: (() -> Void)? = nil) {
        let target = CGPoint(x: x, y: 0)
        container.removeAnimation(forKey: "slide")

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.position = target
            CATransaction.commit()
            completion?()
            return
        }

        let from = container.presentation()?.position ?? container.position
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion?() }
        CATransaction.setDisableActions(true)
        container.position = target

        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: target)
        slide.duration = Settings.shared.transitionDuration
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(slide, forKey: "slide")
        CATransaction.commit()
    }

    // MARK: - Physical desktop still

    /// Grabs a still of the physical desktop so the push transition has
    /// something to slide out. Called as the cursor nears the shared edge, so
    /// the image is already warm by the time the crossing happens.
    func warmSnapshot(of displayID: CGDirectDisplayID, force: Bool = false) {
        guard Settings.shared.usePushTransition, snapshotTask == nil else { return }
        let now = CACurrentMediaTime()
        guard force || now - snapshotCapturedAt > 1.0 else { return }
        snapshotCapturedAt = now

        let width = Int((panelSize.width * scale).rounded())
        let height = Int((panelSize.height * scale).rounded())

        snapshotTask = Task { [weak self] in
            let image = await Self.captureStill(displayID: displayID,
                                                pixelWidth: width,
                                                pixelHeight: height)
            guard let self else { return }
            self.snapshotTask = nil
            guard let image else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.snapshotLayer.contents = image
            CATransaction.commit()
        }
    }

    private static func captureStill(displayID: CGDirectDisplayID,
                                     pixelWidth: Int,
                                     pixelHeight: Int) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.displayP3
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: configuration)
        } catch {
            return nil
        }
    }
}
