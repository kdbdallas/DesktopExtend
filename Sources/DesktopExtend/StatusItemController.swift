import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem

    var onToggleEnabled: (() -> Void)?
    var onSelectSide: ((DesktopSide) -> Void)?
    var onTogglePushTransition: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onOpenLoginItemsSettings: (() -> Void)?
    var onOpenScreenRecordingSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                     accessibilityDescription: "DesktopExtend")
        item.button?.image?.isTemplate = true
    }

    func refresh(enabled: Bool,
                 side: DesktopSide,
                 pushTransition: Bool,
                 status: String,
                 needsPermission: Bool,
                 launchAtLogin: Bool,
                 loginItemNeedsApproval: Bool,
                 isInstalledInApplications: Bool) {
        let menu = NSMenu()

        let statusRow = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        if needsPermission {
            let grant = NSMenuItem(title: "Grant Screen Recording Permission…",
                                   action: #selector(openScreenRecording),
                                   keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)

            let hint = NSMenuItem(
                title: "Enable DesktopExtend, then it starts on its own.",
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: enabled ? "Turn Off Second Desktop"
                                               : "Turn On Second Desktop",
                                action: #selector(toggleEnabled),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let sideMenu = NSMenu()
        for candidate in [DesktopSide.left, .right] {
            let entry = NSMenuItem(title: candidate.displayName,
                                   action: #selector(selectSide(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.state = (candidate == side) ? .on : .off
            entry.representedObject = candidate.rawValue
            sideMenu.addItem(entry)
        }
        let sideRow = NSMenuItem(title: "Second Desktop Is On The", action: nil, keyEquivalent: "")
        menu.addItem(sideRow)
        menu.setSubmenu(sideMenu, for: sideRow)

        let push = NSMenuItem(title: "Slide Transition",
                              action: #selector(togglePush),
                              keyEquivalent: "")
        push.target = self
        push.state = pushTransition ? .on : .off
        menu.addItem(push)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)

        if loginItemNeedsApproval {
            let approve = NSMenuItem(title: "Approve in Login Items…",
                                     action: #selector(openLoginItems),
                                     keyEquivalent: "")
            approve.target = self
            menu.addItem(approve)
        } else if launchAtLogin && !isInstalledInApplications {
            // The login item points at wherever the app is running from, which
            // for a build directory is a bundle that will be replaced.
            let hint = NSMenuItem(title: "Running outside /Applications",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        let permissions = NSMenuItem(title: "Screen Recording Settings…",
                                     action: #selector(openScreenRecording),
                                     keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let quit = NSMenuItem(title: "Quit DesktopExtend", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func togglePush() { onTogglePushTransition?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
    @objc private func openLoginItems() { onOpenLoginItemsSettings?() }
    @objc private func openScreenRecording() { onOpenScreenRecordingSettings?() }
    @objc private func quit() { onQuit?() }

    @objc private func selectSide(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let side = DesktopSide(rawValue: raw) else { return }
        onSelectSide?(side)
    }
}
