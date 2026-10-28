import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

/// Streams a display's contents into a CALayer.
///
/// Frames arrive as IOSurfaces and are handed straight to the layer, so the
/// pixels never round-trip through the CPU — the mirror is a GPU blit.
final class MirrorRenderer: NSObject, SCStreamOutput, SCStreamDelegate {
    let layer = CALayer()

    /// Reported on the main queue when the stream dies (display removed,
    /// permission revoked). The caller decides whether to restart.
    var onStreamStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.port21.DesktopExtend.capture",
                                            qos: .userInteractive)
    /// Retained so the IOSurface currently on screen cannot be recycled beneath us.
    private var presentedBuffer: CVPixelBuffer?
    /// When the last frame reached the layer, on the main queue's clock.
    private var lastFrameAt: CFTimeInterval = 0

    /// Whether a stream is currently attached. A stream can survive a sleep
    /// cycle attached but silent, so this is necessary and not sufficient —
    /// see `secondsSinceLastFrame`.
    var isRunning: Bool { stream != nil }

    /// Seconds since the last frame reached the layer.
    ///
    /// ScreenCaptureKit only emits frames when the captured content changes, so
    /// a large value means nothing on its own. It is evidence of a dead stream
    /// only when something on the captured display is known to be moving.
    var secondsSinceLastFrame: CFTimeInterval {
        lastFrameAt == 0 ? .greatestFiniteMagnitude : CACurrentMediaTime() - lastFrameAt
    }

    override init() {
        super.init()
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
    }

    func start(displayID: CGDirectDisplayID, pointSize: CGSize, scale: CGFloat) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw MirrorError.displayNotCapturable(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // Capture at the display's true backing resolution so the mirror maps
        // 1:1 onto the physical panel with no resampling.
        configuration.width = Int((pointSize.width * scale).rounded())
        configuration.height = Int((pointSize.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = true
        configuration.queueDepth = 6
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.capturesAudio = false

        layer.contentsScale = scale

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        lastFrameAt = CACurrentMediaTime()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        presentedBuffer = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Skip frames the compositor marked idle or blank; presenting them
        // would flash black between real updates.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }

        DispatchQueue.main.async {
            self.lastFrameAt = CACurrentMediaTime()
            self.presentedBuffer = pixelBuffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = surface
            CATransaction.commit()
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            // A stream that was already replaced or shut down deliberately is
            // not a failure, and restarting on its behalf would fight whatever
            // replaced it.
            guard self.stream === stream else { return }
            self.stream = nil
            self.onStreamStopped?(error)
        }
    }
}

enum MirrorError: LocalizedError {
    case displayNotCapturable(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .displayNotCapturable(let id):
            return "ScreenCaptureKit does not list display \(id)."
        }
    }
}
