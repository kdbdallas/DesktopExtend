import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let virtualDisplay = VirtualDisplayManager()
    private let mirror = MirrorRenderer()
    private let cursorWatcher = CursorWatcher()

    private var overlay: OverlayController?
    private var statusItem: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []
    private var geometryTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var watchdogTimer: Timer?
    private var isRestartingMirror = false
    private var lastWatchdogCursor: CGPoint = .zero

    private var isEnabled = false
    private var needsPermission = false
    private var hasRequestedPermission = false
    private var permissionTimer: Timer?
    private var anchorDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var statusText = "Starting…"

    /// How close to the shared edge the cursor gets before the still of the
    /// physical desktop is refreshed, in points.
    private static let snapshotWarmDistance: CGFloat = 200

    /// How long the mirror may go without a frame, while the cursor is visibly
    /// moving across it, before the stream is presumed dead.
    private static let frozenMirrorTimeout: CFTimeInterval = 1.5

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.general.info("""
            DesktopExtend launched — launch-at-login status \
            \(LoginItem.status.rawValue, privacy: .public), \
            installed in /Applications: \(LoginItem.isInstalled, privacy: .public)
            """)
        let status = StatusItemController()
        statusItem = status
        wire(status)
        refreshStatusItem()
        installSignalHandlers()

        guard VirtualDisplayManager.isSupported else {
            statusText = "Unsupported on this macOS build"
            refreshStatusItem()
            presentAlert(
                title: "Virtual displays are unavailable",
                message: "This build of macOS does not expose the private CoreGraphics "
                       + "virtual-display API that DesktopExtend depends on.")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        // Sleep tears down the capture stream and reshuffles every display, and
        // neither is reported through the screen-parameters notification alone.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemWillSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)

        mirror.onStreamStopped = { [weak self] _ in
            guard let self, self.isEnabled else { return }
            Task { await self.restartMirror() }
        }

        Task { await enable() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPermissionPolling()
        stopWatchdog()
        cursorWatcher.stop()
        overlay?.hideImmediately()
        // Releasing the virtual display is what removes it from the WindowServer;
        // skipping this would leave the user with a phantom monitor.
        virtualDisplay.destroy()
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Enable / disable

    private func enable() async {
        guard !isEnabled else { return }

        guard ensureScreenRecordingPermission() else {
            statusText = "Waiting for Screen Recording permission"
            refreshStatusItem()
            return
        }
        guard let initialAnchor = anchorScreen() else {
            Log.display.error("enable aborted: no physical screen to anchor to")
            return
        }
        anchorDisplayID = initialAnchor.displayID
        Log.display.info("""
            anchor display \(self.anchorDisplayID, privacy: .public) \
            \(initialAnchor.frame.width, privacy: .public)x\
            \(initialAnchor.frame.height, privacy: .public) \
            @\(initialAnchor.backingScaleFactor, privacy: .public)x
            """)

        guard virtualDisplay.create(matching: initialAnchor, name: "DesktopExtend") else {
            Log.display.error("enable aborted: virtual display creation failed")
            statusText = "Could not create the display"
            refreshStatusItem()
            return
        }
        guard await virtualDisplay.waitUntilReady() else {
            Log.display.error("enable aborted: display \(self.virtualDisplay.displayID, privacy: .public) never registered")
            virtualDisplay.destroy()
            statusText = "Display never appeared"
            refreshStatusItem()
            return
        }

        let side = Settings.shared.side
        let placed = DisplayArrangement.place(virtual: virtualDisplay.displayID,
                                              nextTo: anchorDisplayID,
                                              side: side)
        Log.display.info("placed display on the \(side.rawValue, privacy: .public): \(placed, privacy: .public)")

        // Re-read the anchor: NSScreen instances captured before the
        // arrangement changed are stale.
        guard let anchor = NSScreen.screens.first(where: { $0.displayID == anchorDisplayID }) else {
            Log.display.error("enable aborted: anchor screen vanished after placement")
            virtualDisplay.destroy()
            return
        }

        let overlay = self.overlay ?? OverlayController(mirror: mirror,
                                                        screenFrame: anchor.frame,
                                                        scale: anchor.backingScaleFactor,
                                                        side: side)
        overlay.update(screenFrame: anchor.frame,
                       scale: anchor.backingScaleFactor,
                       side: side)
        self.overlay = overlay

        do {
            try await mirror.start(displayID: virtualDisplay.displayID,
                                   pointSize: anchor.frame.size,
                                   scale: anchor.backingScaleFactor)
        } catch {
            Log.capture.error("mirror start failed: \(error.localizedDescription, privacy: .public)")
            virtualDisplay.destroy()
            statusText = "Capture failed — \(error.localizedDescription)"
            refreshStatusItem()
            return
        }

        cursorWatcher.anchorDisplay = anchorDisplayID
        cursorWatcher.side = side
        cursorWatcher.onDisplayChange = { [weak self] id in self?.cursorMoved(to: id) }
        cursorWatcher.onApproachEdge = { [weak self] distance in
            guard let self, distance < Self.snapshotWarmDistance else { return }
            self.overlay?.warmSnapshot(of: self.anchorDisplayID)
        }
        cursorWatcher.start()

        isEnabled = true
        startWatchdog()
        Log.general.info("enabled: mirroring display \(self.virtualDisplay.displayID, privacy: .public)")
        statusText = "On — second desktop is to the \(side.displayName.lowercased())"
        refreshStatusItem()
    }

    private func disable() async {
        guard isEnabled else { return }
        isEnabled = false
        wakeTask?.cancel()
        wakeTask = nil
        stopWatchdog()
        cursorWatcher.stop()
        overlay?.hideImmediately()
        await mirror.stop()
        virtualDisplay.destroy()
        statusText = "Off"
        refreshStatusItem()
    }

    /// Restarts capture, retrying while the WindowServer settles.
    ///
    /// After a wake the virtual display can be absent from `SCShareableContent`
    /// for a second or two even though it still exists, so a single attempt
    /// fails for a reason that fixes itself.
    @discardableResult
    private func restartMirror(attempts: Int = 12) async -> Bool {
        guard !isRestartingMirror else { return false }
        isRestartingMirror = true
        defer { isRestartingMirror = false }

        for attempt in 1...attempts {
            guard isEnabled, virtualDisplay.isActive,
                  let anchor = NSScreen.screens.first(where: { $0.displayID == anchorDisplayID })
            else { return false }

            do {
                try await mirror.start(displayID: virtualDisplay.displayID,
                                       pointSize: anchor.frame.size,
                                       scale: anchor.backingScaleFactor)
                Log.capture.info("mirror restarted on attempt \(attempt, privacy: .public)")
                if statusText.hasPrefix("Mirror stopped") {
                    let side = Settings.shared.side
                    statusText = "On — second desktop is to the \(side.displayName.lowercased())"
                    refreshStatusItem()
                }
                return true
            } catch {
                Log.capture.error("""
                    mirror restart attempt \(attempt, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        Log.capture.error("mirror never restarted after \(attempts, privacy: .public) attempts")
        statusText = "Mirror stopped — turn the second desktop off and on"
        refreshStatusItem()
        return false
    }

    // MARK: - Sleep / wake

    /// Parks the capture stream before the machine sleeps. Left running, it
    /// comes back attached but silent — no frames, and no `didStopWithError`
    /// either — which reads as a second desktop whose cursor has stopped moving.
    @objc private func systemWillSleep() {
        guard isEnabled else { return }
        Log.general.info("system sleeping — parking the mirror")
        wakeTask?.cancel()
        overlay?.hideImmediately()
        Task { await mirror.stop() }
    }

    /// Wake reconfigures every display, asynchronously, so recovery waits for
    /// the dust to settle and then retries. Both wake notifications land here;
    /// cancelling and rescheduling coalesces the pair into one attempt.
    @objc private func systemDidWake() {
        guard isEnabled else { return }
        Log.general.info("system woke — rebuilding the mirror")
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.wakeTask = nil
            await self.recoverAfterWake()
        }
    }

    private func recoverAfterWake() async {
        // The virtual display does not always survive a sleep cycle. If the
        // WindowServer dropped it — or the panel it was anchored to came back
        // as a different display — nothing short of rebuilding will do.
        guard virtualDisplay.isActive,
              NSScreen.screens.contains(where: { $0.displayID == virtualDisplay.displayID }),
              NSScreen.screens.contains(where: { $0.displayID == anchorDisplayID })
        else {
            Log.display.error("virtual display did not survive sleep — recreating")
            await disable()
            await enable()
            return
        }

        // Sleep can leave the arrangement shuffled too, which would strand the
        // second desktop somewhere the cursor cannot reach.
        synchronizeGeometry()
        await restartMirror()

        if let location = CGEvent(source: nil)?.location {
            reconcileOverlayWithCursor(at: location)
        }
    }

    /// ScreenCaptureKit can go quiet without ever calling `didStopWithError`,
    /// leaving the overlay showing the last frame it received. The desktop
    /// behind is usually static anyway, so the visible symptom is a cursor that
    /// has stopped moving — which is also the only reliable way to detect it:
    /// the cursor is travelling across the virtual display and no frames arrive.
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMirrorLiveness() }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkMirrorLiveness() {
        guard isEnabled, wakeTask == nil, let overlay,
              let location = CGEvent(source: nil)?.location
        else { return }

        let previous = lastWatchdogCursor
        lastWatchdogCursor = location
        reconcileOverlayWithCursor(at: location)

        guard overlay.isShowingVirtual, !isRestartingMirror,
              abs(location.x - previous.x) > 1 || abs(location.y - previous.y) > 1,
              mirror.secondsSinceLastFrame > Self.frozenMirrorTimeout
        else { return }

        Log.capture.error("""
            no frame in \(self.mirror.secondsSinceLastFrame, privacy: .public)s while the \
            cursor is moving across the second desktop — restarting capture
            """)
        Task { await restartMirror() }
    }

    /// Puts the overlay back in step with whichever display the cursor is
    /// actually on. Sleep hides the overlay while the cursor stays where it
    /// was, so the two disagree on wake — and the watcher reports transitions,
    /// not state, so nothing else would ever correct it.
    private func reconcileOverlayWithCursor(at location: CGPoint) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 8, &ids, &count) == .success, count > 0 else { return }
        cursorMoved(to: ids[0])
    }

    // MARK: - Cursor

    private func cursorMoved(to displayID: CGDirectDisplayID) {
        guard isEnabled, let overlay else { return }
        if displayID == virtualDisplay.displayID {
            overlay.showVirtualDesktop()
        } else {
            // Any real display — not just the anchor — means the mirror
            // should get out of the way.
            overlay.showPhysicalDesktop()
        }
    }

    // MARK: - Display topology

    private func anchorScreen() -> NSScreen? {
        let candidates = NSScreen.screens.filter { $0.displayID != virtualDisplay.displayID }
        return candidates.first { CGDisplayIsBuiltin($0.displayID) != 0 }
            ?? candidates.first { $0.displayID == CGMainDisplayID() }
            ?? candidates.first
    }

    @objc private func screenParametersChanged() {
        // Creating and tearing down our own display fires this too, so settle
        // first and then reconcile against whatever the final topology is.
        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.synchronizeGeometry()
        }
    }

    private func synchronizeGeometry() {
        guard virtualDisplay.isActive,
              let anchor = NSScreen.screens.first(where: { $0.displayID == anchorDisplayID })
        else { return }

        let side = Settings.shared.side
        DisplayArrangement.place(virtual: virtualDisplay.displayID,
                                 nextTo: anchorDisplayID,
                                 side: side)
        overlay?.update(screenFrame: anchor.frame,
                        scale: anchor.backingScaleFactor,
                        side: side)
        cursorWatcher.side = side
    }

    // MARK: - Permissions

    /// Never blocks. macOS treats mirroring as screen recording, and the grant
    /// happens out-of-process in System Settings, so the app waits for it
    /// rather than holding a modal alert open across the whole launch.
    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            needsPermission = false
            return true
        }
        needsPermission = true
        if !hasRequestedPermission {
            hasRequestedPermission = true
            // Registers the app in the Screen & System Audio Recording list
            // and raises the system prompt.
            CGRequestScreenCaptureAccess()
            Log.general.error("Screen Recording permission not granted")
        }
        startPermissionPolling()
        return false
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isEnabled else { return }
                guard CGPreflightScreenCaptureAccess() else { return }
                Log.general.info("Screen Recording permission granted; enabling")
                self.stopPermissionPolling()
                await self.enable()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        needsPermission = false
    }

    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu wiring

    private func wire(_ status: StatusItemController) {
        status.onToggleEnabled = { [weak self] in
            guard let self else { return }
            Task { self.isEnabled ? await self.disable() : await self.enable() }
        }
        status.onSelectSide = { [weak self] side in self?.setSide(side) }
        status.onTogglePushTransition = { [weak self] in
            Settings.shared.usePushTransition.toggle()
            self?.refreshStatusItem()
        }
        status.onToggleLaunchAtLogin = { [weak self] in
            guard let self else { return }
            do {
                try LoginItem.setEnabled(!LoginItem.isEnabled)
                Log.general.info("launch at login -> \(LoginItem.isEnabled, privacy: .public)")
            } catch {
                Log.general.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
                self.presentAlert(title: "Could not change Launch at Login",
                                  message: error.localizedDescription)
            }
            self.refreshStatusItem()
        }
        status.onOpenLoginItemsSettings = { LoginItem.openSettings() }
        status.onOpenScreenRecordingSettings = { [weak self] in
            self?.openScreenRecordingSettings()
        }
        status.onQuit = { NSApp.terminate(nil) }
    }

    private func setSide(_ side: DesktopSide) {
        guard Settings.shared.side != side else { return }
        Settings.shared.side = side
        if isEnabled {
            overlay?.hideImmediately()
            synchronizeGeometry()
            statusText = "On — second desktop is to the \(side.displayName.lowercased())"
        }
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        statusItem?.refresh(enabled: isEnabled,
                            side: Settings.shared.side,
                            pushTransition: Settings.shared.usePushTransition,
                            status: statusText,
                            needsPermission: needsPermission,
                            launchAtLogin: LoginItem.isEnabled,
                            loginItemNeedsApproval: LoginItem.needsApproval,
                            isInstalledInApplications: LoginItem.isInstalled)
    }

    private func presentAlert(title: String,
                              message: String,
                              offerScreenRecordingSettings: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if offerScreenRecordingSettings {
            alert.addButton(withTitle: "Open Settings…")
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if offerScreenRecordingSettings, response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}
