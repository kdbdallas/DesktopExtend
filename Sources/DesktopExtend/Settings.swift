import Foundation

/// Which side of the physical display the second desktop lives on.
enum DesktopSide: String {
    case left
    case right

    var opposite: DesktopSide { self == .left ? .right : .left }
    var displayName: String { self == .left ? "Left" : "Right" }
}

final class Settings {
    static let shared = Settings()

    private enum Key {
        static let side = "secondDesktopSide"
        static let transitionDuration = "transitionDuration"
        static let usePushTransition = "usePushTransition"
    }

    private let defaults = UserDefaults.standard

    /// Defaults to the left, matching the "move the mouse to the far left
    /// edge" behaviour this app was designed around.
    var side: DesktopSide {
        get { DesktopSide(rawValue: defaults.string(forKey: Key.side) ?? "") ?? .left }
        set { defaults.set(newValue.rawValue, forKey: Key.side) }
    }

    var transitionDuration: CFTimeInterval {
        get {
            let stored = defaults.double(forKey: Key.transitionDuration)
            return stored > 0 ? stored : 0.22
        }
        set { defaults.set(newValue, forKey: Key.transitionDuration) }
    }

    /// When true the desktops slide past each other; when false the second
    /// desktop simply fades over the first.
    var usePushTransition: Bool {
        get { defaults.object(forKey: Key.usePushTransition) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.usePushTransition) }
    }
}
