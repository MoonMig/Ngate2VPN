import SwiftUI
import AppKit
import Combine

@main
struct Ngate2VPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        // SwiftUI's App protocol requires a non-empty Scene. The
        // app's actual UI lives in an AppKit-managed window
        // (see AppDelegate.createMainWindow), so we just need a
        // placeholder here. We used to use `Settings { EmptyView() }`,
        // but that came with a hidden side-effect: SwiftUI claimed
        // ownership of the Settings menu item via its SceneOpener,
        // and routed clicks to its own empty Settings scene
        // whenever a modal panel (like the stock About panel) was
        // key window. A plain Window scene doesn't install that
        // handler. We close this placeholder window at launch
        // (see applicationDidFinishLaunching) so it never appears.
        Window("Ngate2VPN Placeholder", id: "ngate2vpn-placeholder") {
            EmptyView()
                .frame(width: 1, height: 1)
        }
        .commands {
            // Help — replaces the auto-injected "<App> Help" item
            // that would otherwise show "Help isn't available".
            CommandGroup(replacing: .help) {
                Button("Ngate2VPN Help") {
                    AppDelegate.shared?.showHelpAlert()
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
            // Services — replace the auto-injected Services submenu
            // with nothing. We don't expose any NSServices, so the
            // entry was just dead weight in the App menu. Previous
            // attempts to strip it post-hoc from NSMenu kept losing
            // because SwiftUI's command system rebuilds the App
            // submenu on its own schedule, re-adding Services
            // between our passes. Telling SwiftUI not to emit it
            // in the first place is the only reliable fix.
            CommandGroup(replacing: .systemServices) { }
            // Settings — inserted right after the App-info block
            // (About, separator). We use SwiftUI's CommandGroup
            // rather than poking NSMenu directly because previous
            // attempts at the AppKit level either produced a stray
            // "NSMenuItem" entry or lost the item entirely after
            // window-state transitions. CommandGroup is the
            // documented API for inserting commands into the
            // standard menu structure and gets the placement right
            // without us having to count indices.
            CommandGroup(after: .appInfo) {
                Button("Settings…") {
                    AppDelegate.shared?.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Shared reference set in `applicationWillFinishLaunching`. Exists
    /// so SwiftUI's `.commands { … }` blocks (which run in the App
    /// scene's isolation, not the AppDelegate's) can call back into
    /// AppKit-side code like alert presentation.
    static weak var shared: AppDelegate?

    let appState = AppState()
    private var mainWindowController: NSWindowController?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    private var statusIconManager: StatusIconManager?
    private var enforcedMinWindowWidth: CGFloat = 380
    /// True while an NSAlert is on screen. Prevents duplicate alerts when
    /// the AppState fires `isAlertPresented = true` multiple times in
    /// quick succession (e.g. one error producing several log lines).
    private var alertIsPresenting = false
    /// Timestamp of the last dismissed alert. Subsequent alerts within
    /// 1.5 seconds are suppressed — this catches the case where ngate
    /// emits two log lines for the same failure.
    private let windowFrameKey = "mainWindowFrame"

    // MARK: - NSWindowDelegate
    // windowWillResize is the only way to GUARANTEE a minimum width.
    // window.minSize alone can be bypassed by setFrame, toolbar reflow, or saved
    // frame restoration. This method is called on every resize attempt and
    // returns the size that will actually be applied.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Window cannot be narrower than the toolbar nor shorter than its width.
        NSSize(
            width:  max(frameSize.width,  enforcedMinWindowWidth),
            height: max(frameSize.height, enforcedMinWindowWidth * 0.75)
        )
    }
    
    private func createMainWindow() -> NSWindowController {
        let contentView = ContentView().environmentObject(appState)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1)
                : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        }

        // Set safe initial size and minimum
        window.setContentSize(NSSize(width: 580, height: 520))
        window.minSize = NSSize(width: enforcedMinWindowWidth, height: enforcedMinWindowWidth * 0.75)

        // We are the window delegate — windowWillResize enforces the min width
        window.delegate = self

        // Embed tab buttons in the titlebar via NSToolbar
        let toolbar = MainToolbar(appState: appState)
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Once the toolbar has had its first layout pass, read the actual width
        // and raise enforcedMinWindowWidth to match. windowWillResize will then
        // prevent the user from making the window narrower than this value.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.layoutIfNeeded()
            // Find tabBar specifically — visibleItems also includes the
            // compensator, and we need the actual button-block width.
            guard let tabBarItem = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier == .tabBar }),
                  let toolbarView = tabBarItem.view else { return }
            toolbarView.layoutSubtreeIfNeeded()
            let toolbarWidth = max(toolbarView.frame.width, toolbarView.fittingSize.width)
            // Layout: [traffic 76][flex N][tabs][flex N][compensator 76]
            // For min-width we ignore the compensator — toolbar simply lets
            // it spill / clip when tight. What we MUST keep visible is tabs
            // plus a small left/right gap.
            let padding: CGFloat = 15
            let computed = trafficLightsWidth + toolbarWidth + padding + 24
            self.enforcedMinWindowWidth = max(computed, 320)
            window.minSize = NSSize(width: self.enforcedMinWindowWidth, height: self.enforcedMinWindowWidth * 0.75)
        }
        
        // Restore the window frame from the last session.
        if let frameData = UserDefaults.standard.data(forKey: windowFrameKey),
           let frame = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: frameData)?.rectValue {
            window.setFrame(frame, display: true)
        }
        
        // Persist window frame on resize and move. We dispatch the
        // save itself onto the next runloop tick to coalesce bursts
        // of resize events (AppKit fires didResize repeatedly during
        // a live drag) and to avoid serializing inside the
        // notification handler.
        let saveHandler: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                self?.saveWindowFrame(window)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main,
            using: saveHandler
        )
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main,
            using: saveHandler
        )
        
        // Hide from the Dock on close (if the option is enabled).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { [weak self] in
                self?.mainWindowWillClose()
            }
        }
        return NSWindowController(window: window)
    }
    
    private func saveWindowFrame(_ window: NSWindow) {
        let frameData = try? NSKeyedArchiver.archivedData(withRootObject: NSValue(rect: window.frame), requiringSecureCoding: false)
        UserDefaults.standard.set(frameData, forKey: windowFrameKey)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the main window must NOT terminate the app — we
        // continue running as a status-bar-only utility. This used to
        // be implicit thanks to the SwiftUI `Settings { ... }` scene
        // we had until 2.34: SwiftUI didn't count that scene as a
        // user-facing window, so the main window was never "the last
        // window" by its accounting. Once we swapped Settings for a
        // plain `Window` placeholder (which IS user-facing in
        // SwiftUI's view), closing the main window started looking
        // like the last-window-closed event and SwiftUI began
        // tearing the app down. Explicit `false` here restores the
        // intended behaviour: app keeps running, tray icon stays
        // live, `mainWindowWillClose` flips activation policy to
        // `.accessory`.
        return false
    }

    private func mainWindowWillClose() {
        guard appState.hideDockOnClose else { return }
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Wipe any per-tunnel credential files left behind by a prior
        // run that crashed or was Force Quit. Each ngate invocation owns
        // its own file with mode 0600; the normal cleanup path deletes it
        // when the process exits, this sweep handles the abnormal one.
        TunnelConfigFile.removeAllStaleConfigs()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowController = createMainWindow()
        setupStatusBar()
        setupAlertObserver()

        // Hook the stock About panel — runs once, takes effect for
        // the lifetime of the process. AppKit calls
        // `orderFrontStandardAboutPanel:` from multiple call sites
        // we don't control, so we override the method itself rather
        // than the menu item that triggers it.
        installAboutPanelSwizzle()

        // We always launch as a regular .regular app (Dock + ability to
        // show modal alerts). The difference with auto-connect is whether
        // the main window is shown.
        NSApp.setActivationPolicy(.regular)

        // SwiftUI's required scene (see App body) is a placeholder
        // `Window` we never want to show. By default macOS auto-opens
        // the first scene at launch; we close it on the next runloop
        // tick. Look for it by identifier, not by index, in case
        // window order shuffles.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.contains("ngate2vpn-placeholder") == true {
                window.close()
            }
        }

        let autoConnect = UserDefaults.standard.bool(forKey: "autoConnect")
        if autoConnect && !appState.tunnels.isEmpty {
            // Silent mode: start tunnels in the background, don't open the
            // main window. NSApp is .regular so any NSAlert that fires will
            // appear immediately without requiring a user click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.appState.connectAll()
            }
        } else {
            showMainWindow()
        }
    }

    /// Hooks `NSApplication.orderFrontStandardAboutPanel(_:)` at the
    /// Obj-C runtime level. AppKit special-cases the About menu item:
    /// no matter what target/action we set on the NSMenuItem, AppKit
    /// calls `orderFrontStandardAboutPanel:` directly on NSApp from
    /// its Apple Event handler. So we override the method itself
    /// rather than the menu item that triggers it.
    ///
    /// Our replacement block routes to `showAboutPanel()`, which
    /// calls `NSApp.orderFrontStandardAboutPanel(options:)` — a
    /// **separate** Obj-C selector (`orderFrontStandardAboutPanel-`
    /// `WithOptions:`) — to present the panel with our custom version
    /// and credits. The options variant is independent of the bare
    /// selector we swizzled, so there's no recursion.
    ///
    /// Runs once at launch and persists for the lifetime of the
    /// process — `method_setImplementation` is a global mutation.
    private func installAboutPanelSwizzle() {
        let cls: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        guard let originalMethod = class_getInstanceMethod(cls, originalSelector) else {
            return
        }

        let replacement: @convention(block) (NSApplication, Any?) -> Void = { _, _ in
            AppDelegate.shared?.showAboutPanel()
        }
        let newImp = imp_implementationWithBlock(replacement)
        method_setImplementation(originalMethod, newImp)
    }

    @objc func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)

        let credits = NSMutableAttributedString(
            string: "Developed by ",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        credits.append(NSAttributedString(
            string: "@H3mul",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.linkColor,
                .link: URL(string: "tg://H3mul") as Any,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        ))

        // We deliberately omit a build number here — the trailing
        // "(1)" the standard panel shows by default is noise: we never
        // increment it independently of the version, so it just adds
        // clutter without conveying any information.
        //
        // Calling the `(options:)` overload is safe — it's a separate
        // Obj-C selector (`orderFrontStandardAboutPanelWithOptions:`),
        // distinct from the one we swizzled
        // (`orderFrontStandardAboutPanel:`). So no recursion, and the
        // options dictionary is the one that actually drives version
        // text and credits.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion:                                version,
            NSApplication.AboutPanelOptionKey(rawValue: "Version"): "",
            .credits:                                            credits
        ])
    }

    /// Shows a panel summarising the most useful things to know about
    /// the app. Wired up via SwiftUI's `CommandGroup(replacing: .help)`
    /// in the App body; that's the only reliable way to override the
    /// auto-injected "App Help" item that produces "Help isn't
    /// available" on systems without a help book.
    func showHelpAlert() {
        let alert = NSAlert()
        alert.messageText = "Ngate2VPN"
        alert.informativeText = """
        VPN-клиент для управления несколькими туннелями Ngate.

        Вкладки
        • Главная — управление туннелями: подключение, отключение, \
        редактирование профилей.
        • Журнал — поток событий в реальном времени с фильтрами \
        Errors / System.
        • Настройки — путь к бинарнику ngate, DNS Helper, тема \
        оформления, поведение приложения.

        DNS Helper
        Устанавливается один раз через Настройки → DNS Helper. После \
        этого split-DNS применяется автоматически и без запроса \
        пароля при каждом подключении / отключении туннеля.

        Логи на диске
        ~/Library/Application Support/NgateVPN/logs/

        Безопасность
        Учётные данные хранятся только в Keychain macOS и в \
        per-process конфигах в \
        ~/Library/Caches/Ngate2VPN/secure-configs/ \
        (права 0600, удаляются при выходе из приложения). За пределы \
        машины ничего не уходит, кроме самого VPN-трафика.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Quit handshake. Several pieces of cleanup must finish before we let
    /// AppKit `exit()`:
    ///
    ///   1. **DNS routes** — wipe `/etc/resolver/<domain>` files we wrote,
    ///      so the user's DNS comes back to its untouched state. Async
    ///      because it shells out via `sudo` to the helper script.
    ///
    ///   2. **Tunnel processes** — `appState.shutdown()` sends SIGINT to
    ///      every running ngate. They take a few hundred ms to exit, and
    ///      we don't actually wait for them — the OS will reap them after
    ///      we're gone.
    ///
    ///   3. **Credential files** — every per-tunnel config in
    ///      `~/Library/Caches/Ngate2VPN/secure-configs/` is now stale,
    ///      because we are exiting. Each ngate's `terminationHandler`
    ///      *would* have deleted its own file, but those handlers fire
    ///      AFTER our app has already left main(), so the files leak.
    ///      We do an explicit directory sweep here as the final step,
    ///      which makes it impossible to leave credentials on disk
    ///      regardless of which signal handler ran first.
    ///
    /// AppKit puts up no UI during this window — the dock icon just shows
    /// the app as "quitting" for the ~half-second the cleanup takes. A
    /// 3-second watchdog forces the reply through anyway so the user is
    /// never stuck unable to quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            // 3-second safety net — if anything below blocks for too long,
            // make sure terminate still goes through.
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    TunnelConfigFile.removeAllStaleConfigs()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }

            // Wipe split-DNS files BEFORE killing the tunnel processes —
            // once tunnels are gone the policy controller resets to empty,
            // but the helper still needs to know which files we own.
            await appState.dnsApplier.wipeAllRoutes()

            appState.persist()
            appState.shutdown()

            // Final unconditional sweep of credential files. Each ngate
            // process *would* clean up after itself via terminationHandler,
            // but those handlers fire after our app exits, so the files
            // would leak. Doing it here makes it deterministic.
            TunnelConfigFile.removeAllStaleConfigs()

            watchdog.cancel()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Close the placeholder if AppKit somehow re-opened it before we get here.
        for window in NSApp.windows where window.identifier?.rawValue.contains("ngate2vpn-placeholder") == true {
            window.close()
        }
        showMainWindow()
        // Return false — we handle the reopen ourselves. Returning true would ask
        // AppKit to also run its default scene-restoration logic, which reopens
        // every previously closed SwiftUI Window scene, including the placeholder.
        return false
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.behavior = .removalAllowed
        statusItem?.isVisible = true
        
        // Initialise the tray icon manager.
        if let item = statusItem {
            statusIconManager = StatusIconManager()
            statusIconManager?.setup(statusItem: item)
            appState.statusIconManager = statusIconManager
        }
        
        menu = NSMenu()
        menu?.delegate = self
        statusItem?.menu = menu
        
        startObserving()
        rebuildMenu()
    }
    
    private func setupAlertObserver() {
        appState.$isAlertPresented
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPresented in
                if isPresented { self?.showAlertWindow() }
            }
            .store(in: &cancellables)
    }
    
    /// Shows a standard macOS NSAlert. The app is launched in .regular mode
    /// from the start, so we just need to bring it to the front before
    /// running the modal — no policy juggling.
    ///
    /// Deduplication and queueing live in `AppState.showAlert(...)` — by
    /// the time we get here, AppState has already decided this alert is
    /// the next one to display.
    private func showAlertWindow() {
        guard let title = appState.alertTitle,
              let message = appState.alertMessage else { return }

        // Re-entry guard. AppKit calls observers synchronously and we
        // sometimes see a duplicate fire while runModal() is still
        // active; ignore those — we'll catch up via the queue when the
        // current alert is dismissed.
        guard !alertIsPresenting else { return }
        alertIsPresenting = true
        defer {
            alertIsPresenting = false
        }

        // ignoringOtherApps brings the alert above whatever app the user is
        // currently in, even if our app is hidden behind everything else.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()

        appState.dismissAlert()
    }

    private func closeAlertWindow() {
        // Native NSAlert dismisses itself on user action — nothing to do here.
        // Kept as a no-op so the existing observer in setupAlertObserver
        // can call it without triggering an Optional-unwrap crash.
    }
    
    private func startObserving() {
        appState.$hideDockOnClose
            .receive(on: DispatchQueue.main)
            .sink { shouldHide in
                if !shouldHide && NSApp.activationPolicy() == .accessory {
                    NSApp.setActivationPolicy(.regular)
                }
            }
            .store(in: &cancellables)
    }
    
    private func rebuildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()
        
        let openItem = NSMenuItem(title: "Open Ngate VPN", action: #selector(openMainWindowToHome), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        // Connect All / Disconnect All — показываем в зависимости от состояния туннелей
        let totalCount = appState.tunnels.count
        let connectedCount = appState.tunnels.filter {
            let s = appState.runtime[$0.id]?.status
            return s == .running || s == .degraded || s == .starting || s == .stopping
        }.count

        // "Connect All" — скрываем только если ВСЕ туннели уже подключены
        if connectedCount < totalCount {
            let connectAllItem = NSMenuItem(title: "Connect All", action: #selector(connectAll), keyEquivalent: "")
            connectAllItem.target = self
            menu.addItem(connectAllItem)
        }

        // "Disconnect All" — скрываем только если НИ ОДИН туннель не подключён
        if connectedCount > 0 {
            let disconnectAllItem = NSMenuItem(title: "Disconnect All", action: #selector(disconnectAll), keyEquivalent: "")
            disconnectAllItem.target = self
            menu.addItem(disconnectAllItem)
        }

        menu.addItem(.separator())

        for tunnel in appState.tunnels {
            guard let snapshot = appState.snapshot(for: tunnel.id) else { continue }
            let isRunning = snapshot.runtime.status == .running || snapshot.runtime.status == .degraded || snapshot.runtime.status == .starting || snapshot.runtime.status == .stopping
            let title = "\(snapshot.configuration.title) (\(snapshot.runtime.status.title))"
            let item = NSMenuItem(title: title, action: #selector(toggleTunnel(_:)), keyEquivalent: "")
            item.representedObject = tunnel.id
            item.target = self
            item.toolTip = isRunning ? "Disconnect" : "Connect"
            menu.addItem(item)
        }
        
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc func showMainWindow() {
        // No async hop. AppDelegate methods are @MainActor; we're
        // already on the main thread when these get called. The
        // previous DispatchQueue.main.async deferred the window
        // ordering by one runloop tick, which raced with state
        // mutations made by callers immediately after — most
        // visibly, `openSettings` setting `selectedTab = .settings`
        // before the window came forward, occasionally leaving
        // SwiftUI rendering in a stale state and showing an empty
        // window.
        guard let window = mainWindowController?.window else { return }
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        if !window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
            if window.isMiniaturized { window.deminiaturize(nil) }
        }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func openSettings() {
        showMainWindow()
        appState.selectedTab = .settings
    }

    /// Tray menu entry "Open Ngate VPN" — always lands on the Home tab,
    /// regardless of which tab was previously active.
    @objc private func openMainWindowToHome() {
        showMainWindow()
        appState.selectedTab = .home
    }

    @objc private func connectAll() {
        appState.connectAll()
    }

    @objc private func disconnectAll() {
        appState.disconnectAll()
    }

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        guard let tunnelId = sender.representedObject as? UUID,
              let status = appState.runtime[tunnelId]?.status else { return }
        if status == .running || status == .degraded || status == .starting || status == .stopping {
            appState.disconnectTunnel(tunnelId)
        } else {
            appState.connectTunnel(tunnelId)
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Only used by the tray (status bar) menu — rebuild the
        // item list based on current tunnel state so the dropdown
        // reflects what's connected. The App submenu in the menu
        // bar is owned by SwiftUI's `.commands { ... }` block and
        // we don't attach as its delegate.
        rebuildMenu()
    }
}


// MARK: - MainToolbar
// Puts the tab buttons directly in the titlebar, right after the traffic lights.
// Using NSToolbar with a single flex-space + custom item is the standard macOS way.

private extension NSToolbarItem.Identifier {
    static let tabBar              = NSToolbarItem.Identifier("tabBar")
    static let flexSpace           = NSToolbarItem.Identifier(NSToolbarItem.Identifier.flexibleSpace.rawValue)
    static let trailingCompensator = NSToolbarItem.Identifier("trailingCompensator")
}

/// Fixed pixel width for the invisible compensator that mirrors the
/// macOS traffic-light reservation on the left edge of the window.
private let trafficLightsWidth: CGFloat = 76

final class MainToolbar: NSToolbar, NSToolbarDelegate, @unchecked Sendable {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(identifier: "Ngate2VPN.MainToolbar")
        self.delegate    = self
        self.displayMode = .iconOnly
        self.showsBaselineSeparator = false
        self.allowsUserCustomization = false
        self.autosavesConfiguration  = false
    }

    // Layout: [traffic 76pt][flex][tabBar][flex][76pt invisible spacer]
    // The right spacer mirrors the traffic-light reservation on the left,
    // making the two flex-spaces grow equally as the window widens.
    // Result: tabBar lands in the true center of the WINDOW.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .tabBar, .flexibleSpace, .trailingCompensator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tabBar, .flexibleSpace, .trailingCompensator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // 76pt invisible spacer that mirrors the traffic-lights region.
        // No bezel, no label — completely transparent layout-only element.
        if itemIdentifier == .trailingCompensator {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spacer.widthAnchor.constraint(equalToConstant: trafficLightsWidth),
                spacer.heightAnchor.constraint(equalToConstant: 1)
            ])
            let item = NSToolbarItem(itemIdentifier: .trailingCompensator)
            item.view = spacer
            item.isBordered = false
            item.label = ""
            item.paletteLabel = ""
            item.toolTip = nil
            item.menuFormRepresentation = nil
            // High priority — compensator must stay visible to keep tabBar
            // centered. Window minimum width is enforced separately, so
            // there's always room for both items.
            item.visibilityPriority = .high
            return item
        }

        guard itemIdentifier == .tabBar else { return nil }

        let tabView = TitlebarTabView().environmentObject(appState)
        let hosting = FocusRingFreeHostingView(rootView: tabView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.heightAnchor.constraint(equalToConstant: 28)
        ])

        let item = NSToolbarItem(itemIdentifier: .tabBar)
        item.view = hosting
        // .user is the highest possible priority — toolbar will never push
        // this item into the overflow menu, so it stays visible at every
        // window width down to enforcedMinWindowWidth.
        item.visibilityPriority = .user
        return item
    }

}


// MARK: - Focus-ring-free hosting view
// SwiftUI re-creates the underlying NSButtons when the selected tab changes,
// which re-enables their focus rings. This subclass intercepts every subview
// addition and recursively disables focus rings, so the blue ring never appears.

final class FocusRingFreeHostingView<Content: View>: NSHostingView<Content> {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        Self.scrub(subview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.scrub(self)
    }

    override func layout() {
        super.layout()
        Self.scrub(self)
    }

    private static func scrub(_ view: NSView) {
        if let button = view as? NSButton {
            button.focusRingType = .none
            button.isBordered    = false
        }
        view.subviews.forEach { scrub($0) }
    }
}

// MARK: - ErrorNotificationView
