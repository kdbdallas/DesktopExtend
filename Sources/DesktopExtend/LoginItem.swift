import Foundation
import ServiceManagement

/// Registers the app as a login item via `SMAppService`.
///
/// `SMAppService` registers whatever bundle is currently running, so a toggle
/// flipped while running out of `build/` would pin the login item to a
/// development bundle that later gets rebuilt over. `isInstalled` lets the menu
/// warn about that.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    /// macOS can require the user to confirm a login item in System Settings
    /// before it takes effect; until then the registration is inert.
    static var needsApproval: Bool { status == .requiresApproval }

    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
