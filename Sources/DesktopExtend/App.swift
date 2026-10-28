import AppKit

@main
enum DesktopExtendApp {
    /// `NSApplication.delegate` is a weak reference, so the delegate is parked
    /// here to keep it alive for the lifetime of the process.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
