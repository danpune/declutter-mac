import AppKit
import Carbon.HIToolbox
import ServiceManagement

// One click (menu bar icon, Dock icon or the shortcut, ⌃⌥D by default) clears every open app, leaving just the
// desktop and the Dock; the next click brings back exactly what it cleared. With Animate on (and Accessibility
// permission) windows minimize into their Dock icons; otherwise it's ⌘H for every app, instant and permission-free.
@main
final class DeClutter: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static func main() {
        let delegate = DeClutter()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    var item: NSStatusItem!
    var hotKeys: [String: EventHotKeyRef] = [:]   // "" is Declutter's shortcut, "focus." is Focus on This App's
    var lastUsed: [pid_t: Date] = [:]             // when each app was last in front, for hiding idle apps
    var axQueues: [pid_t: DispatchQueue] = [:]    // one per app, so its minimizes and un-minimizes run in order
    let startedAt = Date()
    var hidden: [NSRunningApplication] = []
    // Only ordinary apps: right after the front app quits, macOS briefly reports loginwindow, and "restoring" to it
    // leaves the keyboard focused on nothing.
    var lastFront = NSWorkspace.shared.frontmostApplication.flatMap {
        $0.activationPolicy == .regular && $0 != NSRunningApplication.current ? $0 : nil
    }
    var frontBeforeDeclutter: NSRunningApplication?
    var minimized: [AXUIElement] = []   // windows DeClutter minimized (Animate on), un-minimized on Restore
    var generation = 0                  // bumped by Restore, so a pending hide from an unfinished declutter is dropped
    var clearing = false                // windows are on their way to the Dock but the apps aren't hidden yet
    var askedForAccessibility = false
    let defaults = UserDefaults.standard

    // `clearing` covers the 0.6 s before the apps hide, when macOS may not report the windows as minimized yet: a second
    // press then restores instead of decluttering again and losing track of the first windows.
    var isDecluttered: Bool {
        clearing || hidden.contains { $0.isHidden && !$0.isTerminated } || minimized.contains(where: isMinimized)
    }
    var regularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
    }
    // Menu bar utilities: apps with no Dock icon in a bundle of their own. Skips Apple's agents and the helpers that live
    // inside other apps (Chrome, Claude, Signal…), which look the same but would break their app if quit.
    // ponytail: macOS 27 draws every menu bar icon in MenuBarAgent, so "which app owns an icon" isn't visible without
    // Screen Recording; this also catches the odd windowless background agent, which is why Quit asks first.
    var menuBarApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .accessory && $0 != NSRunningApplication.current
                && !($0.bundleIdentifier ?? "com.apple.").hasPrefix("com.apple.")
                && !($0.bundleURL?.pathComponents.dropLast().contains { $0.hasSuffix(".app") } ?? true)
        }
    }
    // Apps the person ticked under "Never Hide or Quit".
    var kept: Set<String> { Set(defaults.stringArray(forKey: "kept") ?? []) }
    func isKept(_ app: NSRunningApplication) -> Bool { kept.contains(app.bundleIdentifier ?? "") }

    func applicationWillFinishLaunching(_ note: Notification) {
        // ponytail: Dock icon on by default: the notch hides menu bar icons on crowded MacBook menu bars.
        let controlOption = Int(NSEvent.ModifierFlags([.control, .option]).rawValue)
        defaults.register(defaults: ["showInDock": true, "animate": true, "checkUpdates": true,
                                     "keyCode": kVK_ANSI_D, "key": "d", "modifiers": controlOption,
                                     "focus.keyCode": kVK_ANSI_F, "focus.key": "f", "focus.modifiers": controlOption])
        applyDockSetting()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DeClutter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()

        // Remember the app the person was using, so Restore puts them back in it (clicking our Dock icon makes us frontmost).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.activationPolicy == .regular, app != NSRunningApplication.current {
                self?.lastFront = app
                self?.lastUsed[app.processIdentifier] = Date()
            }
            self?.updateIcon()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.lastUsed[app.processIdentifier] = nil   // a new app may get the same pid
                self?.axQueues[app.processIdentifier] = nil
            }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.hideIdleApps() }
        // Coming back (wake, display on, unlock, back to this user's session) restarts every idle clock: time away isn't
        // time an app went unused, and counting it would hide all but one app the moment you returned.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.markAllUsed() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in self?.markAllUsed()
        }
        // An app only reports itself hidden a moment after hide(), so the icon follows these instead.
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateIcon()
            }
        }
        // One frozen app can stall any Accessibility call; this caps every one of them (Finder un-minimizes in ~1.5 s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)

        // First launch: open at login, so the shortcut still works after a restart (the menu or System Settings turns
        // it off), and say how DeClutter works.
        if !defaults.bool(forKey: "loginSetUp") {
            defaults.set(true, forKey: "loginSetUp")
            try? SMAppService.mainApp.register()
            DispatchQueue.main.async { self.welcome() }
        }
        // Just updated itself: confirm it once.
        if let version = defaults.string(forKey: "justUpdated") {
            defaults.removeObject(forKey: "justUpdated")
            if version == Self.version { DispatchQueue.main.async { self.confirmUpdate() } }
        }

        // A Carbon hot key needs no Accessibility permission.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                let app = NSApp.delegate as? DeClutter
                id.id == 2 ? app?.focus() : app?.toggle()
            }
            return noErr
        }, 1, &spec, nil, nil)
        registerHotKey("")
        registerHotKey("focus.")

        // A newer version on GitHub is offered once; the hourly tick only goes online when 12 hours have passed.
        autoCheck()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.autoCheck() }

        // `kill`, `killall` and build.sh's reinstall send SIGTERM, which would end the app without the restore above.
        signal(SIGTERM, SIG_IGN)
        terminationSignal.setEventHandler { NSApp.terminate(nil) }
        terminationSignal.resume()
    }
    let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    // Quitting never leaves apps stranded. Waits for the windows to leave the Dock: the process would otherwise exit
    // before the background un-minimize runs.
    func applicationWillTerminate(_ note: Notification) {
        if isDecluttered { _ = restore(hidden).wait(timeout: .now() + 3) }
    }

    // Clicking the Dock icon (or `open -a DeClutter`, e.g. from Spotlight or Raycast) toggles too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }

    // Click: Declutter. Option-click: Focus on This App. Right-click or Control-click (the Mac's other right-click): menu.
    @objc func statusClicked() {
        let event = NSApp.currentEvent, flags = event?.modifierFlags ?? []
        guard event?.type == .rightMouseUp || flags.contains(.control) else { return flags.contains(.option) ? focus() : toggle() }
        let menu = makeMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DeClutter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu              // attach so the menu drops from the icon, then detach so a left click toggles again
        item.button?.performClick(nil)
        item.menu = nil
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let main = menu.addItem(withTitle: isDecluttered ? "Restore Apps" : "Declutter", action: #selector(toggle),
                                keyEquivalent: keyEquivalent(""))
        main.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "modifiers")))
        if !isDecluttered {
            let focusItem = menu.addItem(withTitle: "Focus on \(frontApp?.localizedName ?? "This App")", action: #selector(focus),
                                         keyEquivalent: keyEquivalent("focus."))
            focusItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "focus.modifiers")))
            focusItem.toolTip = "Clears everything except the app you're in. Option-click the menu bar icon does the same."
        }
        menu.addItem(withTitle: "Restore Everything", action: #selector(restoreAll), keyEquivalent: "").toolTip =
            "Brings back every hidden app and every window minimized to the Dock"
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Menu Bar Apps…", action: #selector(quitMenuBarApps), keyEquivalent: "")
        if !(defaults.stringArray(forKey: "quitApps") ?? []).isEmpty {
            menu.addItem(withTitle: "Reopen Menu Bar Apps", action: #selector(reopenMenuBarApps), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Arrange Menu Bar…", action: #selector(openMenuBarSettings), keyEquivalent: "").toolTip =
            "macOS settings to hide icons (other apps' icons on macOS 26 or later). To reorder them, hold ⌘ and drag them in the menu bar."
        menu.addItem(.separator())
        let keepMenu = NSMenu()
        var seen = Set<String>()
        for app in (regularApps + menuBarApps).sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
            let entry = keepMenu.addItem(withTitle: app.localizedName ?? id, action: #selector(toggleKept(_:)), keyEquivalent: "")
            entry.representedObject = id
            entry.state = kept.contains(id) ? .on : .off
            entry.image = app.icon.map { icon in icon.size = NSSize(width: 16, height: 16); return icon }
        }
        menu.addItem(withTitle: "Never Hide or Quit", action: nil, keyEquivalent: "").submenu = keepMenu

        // Things set once live a level down, so the menu stays short.
        let settings = NSMenu()
        settings.addItem(withTitle: "Change Shortcut…", action: #selector(changeShortcut(_:)), keyEquivalent: "").representedObject = ""
        settings.addItem(withTitle: "Change Focus Shortcut…", action: #selector(changeShortcut(_:)), keyEquivalent: "").representedObject = "focus."
        settings.addItem(.separator())
        let animate = settings.addItem(withTitle: "Animate", action: #selector(toggleAnimate), keyEquivalent: "")
        animate.state = defaults.bool(forKey: "animate") ? .on : .off
        animate.toolTip = "Windows shrink into their Dock icons instead of vanishing. Needs Accessibility permission."
        let oneScreen = settings.addItem(withTitle: "Only the Screen Under the Pointer", action: #selector(toggleOneScreen), keyEquivalent: "")
        oneScreen.state = defaults.bool(forKey: "oneScreen") ? .on : .off
        oneScreen.toolTip = "With more than one display, clears only the one your pointer is on. Needs Accessibility permission."
        let idle = NSMenu()
        for minutes in [0, 5, 15, 30, 60] {
            let choice = idle.addItem(withTitle: minutes == 0 ? "Never" : minutes == 60 ? "1 Hour" : "\(minutes) Minutes",
                                      action: #selector(setIdleMinutes(_:)), keyEquivalent: "")
            choice.tag = minutes
            choice.state = defaults.integer(forKey: "idleMinutes") == minutes ? .on : .off
            choice.target = self
        }
        let idleItem = settings.addItem(withTitle: "Hide Apps Not Used For", action: nil, keyEquivalent: "")
        idleItem.submenu = idle
        idleItem.toolTip = "Hides apps you haven't switched to in that time, like ⌘H. Keep apps you watch or listen to "
            + "without switching to them (video, music, calls) under Never Hide or Quit."
        settings.addItem(.separator())
        settings.addItem(withTitle: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "").state =
            defaults.bool(forKey: "showInDock") ? .on : .off
        settings.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "").state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        let auto = settings.addItem(withTitle: "Check for Updates Automatically", action: #selector(toggleAutoCheck), keyEquivalent: "")
        auto.state = defaults.bool(forKey: "checkUpdates") ? .on : .off
        auto.toolTip = "Asks GitHub for a newer version at start and every 12 hours. Only DeClutter's version is sent."
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings

        menu.addItem(.separator())
        menu.addItem(withTitle: "About DeClutter \(Self.version)", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: release.map { "Update to Version \($0.version)…" } ?? "Check for Updates…",
                     action: #selector(checkNow), keyEquivalent: "")
        for item in menu.items + keepMenu.items + settings.items { item.target = self }
        return menu
    }

    // The app the person is in. Right after launch no switch has been seen yet; then it's the one in front now.
    var frontApp: NSRunningApplication? {
        if let lastFront, !lastFront.isTerminated { return lastFront }
        return NSWorkspace.shared.frontmostApplication.flatMap {
            $0.activationPolicy == .regular && $0 != NSRunningApplication.current ? $0 : nil
        }
    }

    @objc func toggle() { declutter(keeping: nil) }
    @objc func focus() {
        guard isDecluttered || frontApp != nil else { return NSSound.beep() }   // no app to keep: don't clear them all instead
        declutter(keeping: frontApp)
    }

    // The Focus item needs an app to keep. (Setting isEnabled wouldn't stick: the menu re-enables its items.)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(focus) || frontApp != nil
    }

    // A shortcut shows in the menu only while it's really registered, not when another app got it first.
    func keyEquivalent(_ prefix: String) -> String {
        hotKeys[prefix] == nil ? "" : defaults.string(forKey: prefix + "key") ?? ""
    }

    // Clears every app, or with `keeping` (Focus on This App) every app but that one. Done again, it restores.
    func declutter(keeping focus: NSRunningApplication?) {
        guard !isDecluttered else { restore(hidden); return }
        // Apps the person had already hidden stay hidden on Restore.
        let apps = regularApps.filter { !$0.isHidden && !isKept($0) && $0 != focus }
        frontBeforeDeclutter = frontApp
        if defaults.bool(forKey: "oneScreen"), NSScreen.screens.count > 1, hasAccessibility,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            return clearScreen(screen, of: apps)
        }
        guard !apps.isEmpty else { return NSSound.beep() }   // nothing to clear: say so, the Mac way
        // Take focus first, or hiding the front app makes macOS switch to (and show) another app. Focus keeps its app.
        if focus == nil { NSApp.activate() }
        hidden = apps
        guard defaults.bool(forKey: "animate"), hasAccessibility else {
            hidden.forEach { $0.hide() }
            focus?.activate()
            return updateIcon()
        }
        // Each app's front window animates into its Dock icon; then the apps are hidden, taking their other windows and
        // whatever can't minimize (palettes, full-screen windows) with them. One window per app, because an app plays
        // its minimize animations one after another: minimizing every window left a ~3 s trickle (Finder, 6 windows).
        minimized = hidden.compactMap { windows(of: $0).first { isStandard($0) && !isMinimized($0) } }
        minimized.forEach { setMinimized($0, true) }
        clearing = true
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            guard current == generation else { return }
            clearing = false
            hidden.forEach { $0.hide() }
            focus?.activate()   // after a Dock click DeClutter is in front; hand it back
            updateIcon()
        }
        updateIcon()
    }

    // One display only: hiding an app would take its windows on the other displays too, so every window on this one
    // goes to the Dock instead and the apps stay. Restore brings back exactly those windows.
    // ponytail: an app minimizes its windows one after another, so one with many windows here takes a moment.
    func clearScreen(_ screen: NSScreen, of apps: [NSRunningApplication]) {
        minimized = apps.flatMap(windows(of:)).filter { isStandard($0) && !isMinimized($0) && self.screen(of: $0) == screen }
        guard !minimized.isEmpty else { return NSSound.beep() }
        hidden = []
        clearing = true   // as in declutter: a second press while the windows are on their way restores them
        let current = generation
        setMinimized(minimized, to: true).notify(queue: .main) { [self] in
            guard current == generation else { return }
            clearing = false   // only once they've all landed, so the icon can't flip back early
            updateIcon()
        }
        updateIcon()
    }

    // The display holding a window's centre. Accessibility measures from the top-left of the main display, AppKit
    // from its bottom-left.
    func screen(of window: AXUIElement) -> NSScreen? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(window, kAXPositionAttribute), let extent = attribute(window, kAXSizeAttribute),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size),
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let centre = CGPoint(x: origin.x + size.width / 2, y: top - origin.y - size.height / 2)
        return NSScreen.screens.first { $0.frame.contains(centre) }
    }

    // Hides apps that haven't been in front for the chosen time, like ⌘H. Never the front app, a kept one, while the
    // screen is clear, or while you're away. An app open before DeClutter started counts from DeClutter's start.
    func hideIdleApps() {
        let minutes = defaults.integer(forKey: "idleMinutes")
        guard minutes > 0, !isDecluttered, !isAway else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let front = NSWorkspace.shared.frontmostApplication
        for app in regularApps where !app.isHidden && !isKept(app) && app != front {
            let since = lastUsed[app.processIdentifier] ?? max(app.launchDate ?? startedAt, startedAt)
            if since < cutoff { app.hide() }
        }
    }

    // Screen locked, display asleep, or another user's session in front: nothing is in use, so nothing is unused.
    var isAway: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSSessionOnConsoleKey"] as? Bool == false
            || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    func markAllUsed() {
        let now = Date()
        for app in regularApps { lastUsed[app.processIdentifier] = now }
    }

    @objc func setIdleMinutes(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "idleMinutes")
    }

    @objc func toggleOneScreen() {
        defaults.set(!defaults.bool(forKey: "oneScreen"), forKey: "oneScreen")
        if defaults.bool(forKey: "oneScreen") {
            askedForAccessibility = false   // it needs the permission, so ask now rather than silently doing everything
            _ = hasAccessibility
        }
    }

    @objc func restoreAll() {
        restore(regularApps.filter(\.isHidden))
        guard hasAccessibility else { return }   // until it's granted, this still brings back the hidden apps
        setMinimized(regularApps.flatMap(windows(of:)).filter(isMinimized), to: false)
    }

    // Minimizing can block until the app finishes its animation (1.5 s in Finder), so each app gets its own serial
    // queue: one slow app doesn't hold up the others, DeClutter stays responsive, and an app's un-minimize always runs
    // after its minimize (a fast second press could otherwise leave windows in the Dock). Called on the main thread.
    // The group finishes when all are done.
    @discardableResult func setMinimized(_ windows: [AXUIElement], to on: Bool) -> DispatchGroup {
        let done = DispatchGroup()
        let byApp = Dictionary(grouping: windows) { window -> pid_t in
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            return pid
        }
        for (pid, group) in byApp {
            let queue = axQueues[pid] ?? DispatchQueue(label: "DeClutter.ax.\(pid)", qos: .userInteractive)
            axQueues[pid] = queue
            queue.async(group: done) {
                group.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, on as CFBoolean) }
            }
        }
        return done
    }

    @discardableResult func restore(_ apps: [NSRunningApplication]) -> DispatchGroup {
        generation += 1
        clearing = false
        // macOS only lets the active app hand focus to another, so take it first. It must come before unhide(): that
        // request is asynchronous, and activating right after it left every app hidden.
        NSApp.activate()
        apps.forEach { $0.unhide() }
        let done = setMinimized(minimized, to: false)
        minimized = []
        markAllUsed()   // just brought back, so not idle: otherwise "Hide Apps Not Used For" would hide them again
        // lastFront when nothing was decluttered (Restore Everything), or when the app the person was in has quit since.
        [frontBeforeDeclutter, lastFront].compactMap { $0 }.first { !$0.isTerminated }?.activate()
        frontBeforeDeclutter = nil
        hidden = []
        updateIcon()
        return done
    }

    // Minimizing other apps' windows needs Accessibility permission. macOS asks at most once per launch; until it's
    // granted, DeClutter hides instead. The grant survives rebuilds because build.sh signs with a local certificate.
    var hasAccessibility: Bool {
        defer { askedForAccessibility = true }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !askedForAccessibility] as CFDictionary)
    }

    func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)   // tighter than the global 2 s: one frozen app barely delays a declutter
        return attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    // An ordinary window, not a palette or dialog. Only true while it's on screen: macOS 27 reports a minimized window
    // as AXDialog, so Restore Everything must not filter on this.
    func isStandard(_ window: AXUIElement) -> Bool {
        attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    func isMinimized(_ window: AXUIElement) -> Bool { attribute(window, kAXMinimizedAttribute) as? Bool == true }

    func setMinimized(_ window: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, on as CFBoolean)
    }

    @objc func toggleAnimate() {
        defaults.set(!defaults.bool(forKey: "animate"), forKey: "animate")
        if defaults.bool(forKey: "animate") {
            askedForAccessibility = false   // turning it on is a good moment to ask again
            _ = hasAccessibility
        }
    }

    @objc func toggleKept(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var ids = kept
        if ids.remove(id) == nil { ids.insert(id) }
        defaults.set(Array(ids), forKey: "kept")
    }

    @objc func quitMenuBarApps() {
        let apps = menuBarApps.filter { !isKept($0) }
        NSApp.activate()
        defer { returnToLastApp() }
        let alert = NSAlert()
        guard !apps.isEmpty else {
            alert.messageText = "No menu bar apps to quit"
            alert.informativeText = "Apps under Never Hide or Quit are left running."
            alert.runModal()
            return
        }
        alert.messageText = apps.count == 1 ? "Quit 1 menu bar app?" : "Quit \(apps.count) menu bar apps?"
        alert.informativeText = apps.compactMap(\.localizedName).sorted().joined(separator: "\n")
            + "\n\nReopen Menu Bar Apps brings them back. To keep one running, tick it under Never Hide or Quit."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Saved, so Reopen still works after DeClutter restarts.
        let ids = Set((defaults.stringArray(forKey: "quitApps") ?? []) + apps.compactMap(\.bundleIdentifier))
        defaults.set(Array(ids), forKey: "quitApps")
        apps.forEach { $0.terminate() }
    }

    // Once a dialog closes, back to the app the person was in, unless the screen is clear: activating a hidden app
    // would bring it back.
    func returnToLastApp() {
        if !isDecluttered { lastFront?.activate() }
    }

    @objc func reopenMenuBarApps() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        for id in defaults.stringArray(forKey: "quitApps") ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
        defaults.removeObject(forKey: "quitApps")
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString()
        for (i, (title, link)) in [("What's New", "https://github.com/danpune/declutter-mac/releases"),
                                   ("Source on GitHub", "https://github.com/danpune/declutter-mac")].enumerated() {
            if i > 0 { credits.append(NSAttributedString(string: "   ·   ")) }
            credits.append(NSAttributedString(string: title, attributes: [.link: URL(string: link)!]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttributes([.paragraphStyle: centered, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
                              range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Updates
    // DeClutter asks GitHub for the latest release, and Update installs it in place: no browser download, so no
    // "Open Anyway" again. A download is installed only if it's signed with the same certificate as this copy (its
    // designated requirement), so nothing else can get in this way. The certificate never leaves the owner's Mac.

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    var release: Release?      // a newer version than this one, once a check has found it
    var lastCheck: Date?

    // Only DeClutter's version goes with a request; the default User-Agent would add the macOS (Darwin) version.
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("DeClutter/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func isNewer(_ version: String) -> Bool { version.compare(Self.version, options: .numeric) == .orderedDescending }

    func fetchLatest(_ done: @escaping (Release?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/danpune/declutter-mac/releases/latest")!
        URLSession.shared.dataTask(with: Self.request(url)) { data, _, _ in
            let found = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { [self] in
                if let found {
                    lastCheck = Date()
                    release = Self.isNewer(found.version) ? found : nil
                }
                done(found)
            }
        }.resume()
    }

    func autoCheck() {
        guard defaults.bool(forKey: "checkUpdates") else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 12 * 3600 { return announce() }
        fetchLatest { [self] _ in announce() }
    }

    // Each new version is offered once, never while the screen is clear or over another DeClutter dialog (the next
    // hourly tick tries again); after that it waits in the menu.
    func announce() {
        guard let release, defaults.string(forKey: "announced") != release.version, !isDecluttered, NSApp.modalWindow == nil
        else { return }
        defaults.set(release.version, forKey: "announced")
        offer(release, unasked: true)
    }

    @objc func checkNow() {
        fetchLatest { [self] found in
            if let release { return offer(release) }
            NSApp.activate()
            defer { returnToLastApp() }
            let alert = NSAlert()
            alert.messageText = found == nil ? "Couldn't check for updates" : "DeClutter is up to date"
            alert.informativeText = found == nil ? "DeClutter couldn't reach GitHub. Check your internet connection and try again."
                                                 : "Version \(Self.version) is the newest version."
            alert.runModal()
        }
    }

    func offer(_ release: Release, unasked: Bool = false) {
        NSApp.activate()
        defer { returnToLastApp() }
        let alert = NSAlert()
        alert.messageText = "DeClutter \(release.version) is available"
        alert.informativeText = "You have version \(Self.version). Update installs it and reopens DeClutter; "
            + "your settings and Accessibility permission stay as they are."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Later")
        if unasked {   // nobody asked: Return means Later, so typing into another app can't start an update
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[2].keyEquivalent = "\r"
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.html_url)
        default: break
        }
    }

    // ponytail: no progress bar; the zip is ~300 KB, so it's done in a moment.
    func install(_ release: Release) {
        guard let zip = release.assets.first(where: { $0.name == "DeClutter-mac.zip" })?.browser_download_url else {
            return installFailed(release)
        }
        URLSession.shared.downloadTask(with: Self.request(zip)) { file, _, _ in
            // The downloaded file is deleted once this returns, so the swap happens here, off the main thread.
            let installed = file.map { self.replaceApp(withZip: $0, version: release.version) } ?? false
            DispatchQueue.main.async {
                guard installed else { return self.installFailed(release) }
                self.defaults.set(release.version, forKey: "justUpdated")   // the new copy confirms it
                self.relaunch()
            }
        }.resume()
    }

    // Unzips into a private folder on the app's own volume, checks it's DeClutter at that version, signed like this copy
    // and able to run on this Mac, then swaps it in. Anything off leaves this copy untouched.
    func replaceApp(withZip zip: URL, version: String) -> Bool {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
        else { return false }
        defer { try? fm.removeItem(at: dir) }
        guard let ditto = try? Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, dir.path])
        else { return false }
        ditto.waitUntilExit()
        let new = dir.appendingPathComponent("DeClutter.app")
        guard ditto.terminationStatus == 0, signedLikeThisCopy(new), runsHere(new),
              Bundle(url: new)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { return false }
        return (try? fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: new)) != nil
    }

    // A version that needs a newer macOS, or leaves out this Mac's kind of processor, would replace a working copy with
    // one that won't open. Such an update is refused, and the person is offered the download page instead.
    func runsHere(_ app: URL) -> Bool {
        guard let bundle = Bundle(url: app) else { return false }
        let minimum = (bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "0")
            .split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        #if arch(arm64)
        let processor = NSBundleExecutableArchitectureARM64
        #else
        let processor = NSBundleExecutableArchitectureX86_64
        #endif
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: minimum[0], minorVersion: minimum[1], patchVersion: minimum[2]))
            && (bundle.executableArchitectures ?? []).contains(NSNumber(value: processor))
    }

    func signedLikeThisCopy(_ app: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                                          requirement) == errSecSuccess
    }

    // Quits (restoring a clear screen first, as any quit does); a tiny shell waits for this process to end and opens
    // the new copy. It retries only when `open` itself fails (right after the swap LaunchServices sometimes refuses
    // once): opening a copy that's already running would count as a click and clear the screen.
    func relaunch() {
        let wait = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; "
            + "for i in 1 2 3 4 5; do open -g \"$0\" && break; sleep 1; done"   // -g: you stay in the app you're in
        guard (try? Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", wait, Bundle.main.bundlePath])) != nil else {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "DeClutter is updated"
            alert.informativeText = "Quit DeClutter and open it again to start the new version."
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }

    func installFailed(_ release: Release) {
        NSApp.activate()
        defer { returnToLastApp() }
        let alert = NSAlert()
        alert.messageText = "DeClutter couldn't update itself"
        alert.informativeText = "Download version \(release.version) from GitHub instead, then replace DeClutter in Applications."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.html_url) }
    }

    func confirmUpdate() {
        NSApp.activate()
        defer { returnToLastApp() }
        let alert = NSAlert()
        alert.messageText = "DeClutter is now version \(Self.version)"
        alert.informativeText = "The update is installed."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "What's New")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/danpune/declutter-mac/releases/tag/v\(Self.version)")!)
        }
    }

    // First launch only. Asking for Accessibility here, with the reason, beats macOS's bare prompt in the middle of
    // the first declutter.
    func welcome() {
        NSApp.activate()
        defer { returnToLastApp() }
        let alert = NSAlert()
        alert.messageText = "DeClutter is ready"
        alert.informativeText = "Click the green icon in the menu bar or the Dock, or press \(shortcutName("") ?? "your shortcut"), "
            + "and every window tucks into the Dock. Do it again to bring everything back.\n\n"
            + "To keep just the app you're in, Option-click the icon or press \(shortcutName("focus.") ?? "the Focus shortcut"). "
            + "Right-click the icon for options."
        guard !AXIsProcessTrusted() else { return _ = alert.runModal() }
        alert.informativeText += "\n\nTo watch windows shrink into the Dock, DeClutter needs Accessibility permission. "
            + "Without it, windows simply vanish."
        alert.addButton(withTitle: "Allow Animation…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            askedForAccessibility = false
            _ = hasAccessibility   // macOS's own prompt, which opens System Settings
        } else {
            defaults.set(false, forKey: "animate")   // no surprise prompt later; turning Animate on asks again
        }
    }

    @objc func toggleAutoCheck() {
        defaults.set(!defaults.bool(forKey: "checkUpdates"), forKey: "checkUpdates")
        autoCheck()
    }

    // macOS 26+ has its own menu bar manager: System Settings > Menu Bar > Allow in the Menu Bar.
    @objc func openMenuBarSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
    }

    // The menu item carries which shortcut: "" for Declutter, "focus." for Focus on This App.
    @objc func changeShortcut(_ sender: NSMenuItem) {
        let prefix = sender.representedObject as? String ?? ""
        let names = ["keyCode", "key", "modifiers"].map { prefix + $0 }
        let old = names.map { defaults.object(forKey: $0) }
        let other = prefix.isEmpty ? "focus." : ""
        // Both off while recording: pressing the current one records it instead of running it, and the other can't
        // clear the screen behind the dialog.
        for p in [prefix, other] {
            if let ref = hotKeys[p] { UnregisterEventHotKey(ref) }
            hotKeys[p] = nil
        }
        let alert = NSAlert()
        alert.messageText = prefix.isEmpty ? "Press your new DeClutter shortcut" : "Press your new Focus on This App shortcut"
        alert.informativeText = (shortcutName(prefix).map { "Now: \($0). " } ?? "")
            + "Hold ⌘, ⌃ or ⌥ (⇧ optional) and press a key. Esc keeps the current shortcut."
        alert.addButton(withTitle: "Cancel")
        var reserved = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.abortModal()
            } else if !mods.isDisjoint(with: [.command, .control, .option]), let key = event.charactersIgnoringModifiers?.lowercased() {
                reserved = isReserved(event.keyCode, mods, key)
                    || (Int(event.keyCode) == defaults.integer(forKey: other + "keyCode")
                        && Int(mods.rawValue) == defaults.integer(forKey: other + "modifiers"))
                if !reserved {
                    defaults.set(Int(event.keyCode), forKey: prefix + "keyCode")
                    defaults.set(key, forKey: prefix + "key")
                    defaults.set(Int(mods.rawValue), forKey: prefix + "modifiers")
                }
                NSApp.stopModal()
            }
            return nil   // swallow every key so Return or Space can't press Cancel by accident
        }
        NSApp.activate()
        defer { returnToLastApp() }
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        registerHotKey(other)
        if reserved || !registerHotKey(prefix) {
            for (name, value) in zip(names, old) { defaults.set(value, forKey: name) }
            registerHotKey(prefix)
            let taken = NSAlert()
            taken.messageText = "That shortcut is already taken"
            taken.informativeText = "macOS, every app, or DeClutter's other shortcut uses it (like ⌘Space or ⌘C). "
                + "DeClutter kept the previous one; try another combination."
            taken.runModal()
        }
    }

    // macOS's own shortcuts (Spotlight, app switching, screenshots…, as set in System Settings > Keyboard) and the ⌘ keys
    // every app relies on. Registering over them succeeds silently and then breaks them everywhere, so refuse up front.
    // ponytail: other apps' own in-app shortcuts can't be looked up; the README says to pick one you don't use.
    func isReserved(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags, _ key: String) -> Bool {
        if mods == .command && ["q", "w", "c", "v", "x", "z", "a", "s", "h"].contains(key) { return true }   // quit, close, edit, save, hide
        if mods == [.command, .shift] && ["z", "q"].contains(key) { return true }   // redo, log out
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let system = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let carbon = carbonModifiers(mods), mask = cmdKey | controlKey | optionKey | shiftKey
        return system.contains {
            $0[kHISymbolicHotKeyEnabled as String] as? Bool == true && $0[kHISymbolicHotKeyCode as String] as? Int == Int(keyCode)
                && ($0[kHISymbolicHotKeyModifiers as String] as? Int ?? 0) & mask == carbon
        }
    }

    // A shortcut as the menu shows it, like ⌃⌥D; nil for keys with no printable name (F-keys, arrows).
    func shortcutName(_ prefix: String) -> String? {
        let mods = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: prefix + "modifiers")))
        guard let key = defaults.string(forKey: prefix + "key"), let scalar = key.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(scalar.value), !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { mods.contains($0.0) }.map(\.1).joined() + (key == " " ? "Space" : key.uppercased())
    }

    func carbonModifiers(_ mods: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if mods.contains(.command) { carbon |= cmdKey }
        if mods.contains(.control) { carbon |= controlKey }
        if mods.contains(.option) { carbon |= optionKey }
        if mods.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    // Hot key id 1 is Declutter, 2 is Focus on This App (the event handler tells them apart by it).
    @discardableResult func registerHotKey(_ prefix: String) -> Bool {
        let mods = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: prefix + "modifiers")))
        var ref: EventHotKeyRef?
        let ok = RegisterEventHotKey(UInt32(defaults.integer(forKey: prefix + "keyCode")), UInt32(carbonModifiers(mods)),
                                     EventHotKeyID(signature: OSType(0x4443_4C52), id: prefix.isEmpty ? 1 : 2),
                                     GetApplicationEventTarget(), 0, &ref) == noErr
        hotKeys[prefix] = ref
        return ok
    }

    @objc func toggleDock() {
        defaults.set(!defaults.bool(forKey: "showInDock"), forKey: "showInDock")
        applyDockSetting()
    }

    func applyDockSetting() {
        NSApp.setActivationPolicy(defaults.bool(forKey: "showInDock") ? .regular : .accessory)
    }

    @objc func toggleLogin() {
        let login = SMAppService.mainApp
        // Once it's switched off in System Settings > Login Items, only the person can switch it back on, there.
        guard login.status != .requiresApproval else { return SMAppService.openSystemSettingsLoginItems() }
        do { try login.status == .enabled ? login.unregister() : login.register() }
        catch { SMAppService.openSystemSettingsLoginItems() }
    }

    func updateIcon() {
        let on = isDecluttered
        // Green, to match the app icon and stay distinct from look-alike sparkle icons (Gemini) in the menu bar.
        item?.button?.image = NSImage(systemSymbolName: on ? "arrow.uturn.backward.circle" : "macwindow.on.rectangle",
                                      accessibilityDescription: on ? "Restore apps" : "Declutter")?
            .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
        item?.button?.toolTip = (on ? "Restore apps" : "Declutter") + " · right-click for options"
    }
}
