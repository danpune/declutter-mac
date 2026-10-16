import AppKit
import Carbon.HIToolbox
import ServiceManagement

// One click (menu bar icon, Dock icon or the shortcut, ⌃⌥D by default) clears every open app, leaving just the
// desktop and the Dock; the next click brings back exactly what it cleared. With Animate on (and Accessibility
// permission) windows minimize into their Dock icons; otherwise it's ⌘H for every app, instant and permission-free.
@main
final class DeClutter: NSObject, NSApplicationDelegate {
    static func main() {
        let delegate = DeClutter()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    var item: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var hidden: [NSRunningApplication] = []
    // Only ordinary apps: right after the front app quits, macOS briefly reports loginwindow, and "restoring" to it
    // leaves the keyboard focused on nothing.
    var lastFront = NSWorkspace.shared.frontmostApplication.flatMap { $0.activationPolicy == .regular ? $0 : nil }
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
        defaults.register(defaults: ["showInDock": true, "animate": true, "keyCode": kVK_ANSI_D, "key": "d",
                                     "modifiers": Int(NSEvent.ModifierFlags([.control, .option]).rawValue)])
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
            if let app, app.activationPolicy == .regular, app != NSRunningApplication.current { self?.lastFront = app }
            self?.updateIcon()
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

        // Open at login once, so the shortcut still works after a restart. The menu or System Settings turns it off.
        if !defaults.bool(forKey: "loginSetUp") {
            defaults.set(true, forKey: "loginSetUp")
            try? SMAppService.mainApp.register()
        }

        // A Carbon hot key needs no Accessibility permission.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? DeClutter)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        registerHotKey()

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

    @objc func statusClicked() {
        let event = NSApp.currentEvent   // Control-click is the Mac's other right-click
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else { return toggle() }
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
                                keyEquivalent: defaults.string(forKey: "key") ?? "")
        main.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "modifiers")))
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
            entry.target = self
            entry.image = app.icon.map { icon in icon.size = NSSize(width: 16, height: 16); return icon }
        }
        menu.addItem(withTitle: "Never Hide or Quit", action: nil, keyEquivalent: "").submenu = keepMenu
        menu.addItem(withTitle: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        let animate = menu.addItem(withTitle: "Animate", action: #selector(toggleAnimate), keyEquivalent: "")
        animate.state = defaults.bool(forKey: "animate") ? .on : .off
        animate.toolTip = "Windows shrink into their Dock icons instead of vanishing. Needs Accessibility permission."
        menu.addItem(withTitle: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "").state =
            defaults.bool(forKey: "showInDock") ? .on : .off
        menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "").state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(withTitle: "Version \(version) · What's New", action: #selector(openReleases), keyEquivalent: "").toolTip =
            "Every version and what changed, newest first. DeClutter doesn't update itself, so get newer versions here."
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func toggle() {
        guard !isDecluttered else { restore(hidden); return }
        // Right after launch no switch has been seen yet; then the app in front now (shortcut or menu bar) is the one.
        frontBeforeDeclutter = lastFront ?? NSWorkspace.shared.frontmostApplication.flatMap {
            $0.activationPolicy == .regular && $0 != NSRunningApplication.current ? $0 : nil
        }
        NSApp.activate()   // take focus first, or hiding the front app makes macOS switch to (and show) another app
        hidden = regularApps.filter { !$0.isHidden && !isKept($0) }   // apps the person had already hidden stay hidden on Restore
        guard defaults.bool(forKey: "animate"), hasAccessibility else {
            hidden.forEach { $0.hide() }
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
            updateIcon()
        }
        updateIcon()
    }

    @objc func restoreAll() {
        restore(regularApps.filter(\.isHidden))
        guard hasAccessibility else { return }   // until it's granted, this still brings back the hidden apps
        unminimize(regularApps.flatMap(windows(of:)).filter(isMinimized))
    }

    // Un-minimizing can block until the app finishes its animation (1.5 s in Finder), so each app gets its own queue:
    // one slow app no longer holds up the others, and DeClutter stays responsive. The group finishes when all are done.
    @discardableResult func unminimize(_ windows: [AXUIElement]) -> DispatchGroup {
        let done = DispatchGroup()
        let byApp = Dictionary(grouping: windows) { window -> pid_t in
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            return pid
        }
        for group in byApp.values {
            DispatchQueue.global(qos: .userInteractive).async(group: done) {
                group.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
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
        let done = unminimize(minimized)
        minimized = []
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

    @objc func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/danpune/declutter-mac/releases")!)
    }

    // macOS 26+ has its own menu bar manager: System Settings > Menu Bar > Allow in the Menu Bar.
    @objc func openMenuBarSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
    }

    @objc func changeShortcut() {
        let old = (defaults.integer(forKey: "keyCode"), defaults.string(forKey: "key"), defaults.integer(forKey: "modifiers"))
        if let hotKey { UnregisterEventHotKey(hotKey) }   // so pressing the current shortcut records it instead of running it
        hotKey = nil
        let alert = NSAlert()
        alert.messageText = "Press your new DeClutter shortcut"
        alert.informativeText = "Hold ⌘, ⌃ or ⌥ (⇧ optional) and press a key. Esc keeps the current shortcut."
        alert.addButton(withTitle: "Cancel")
        var reserved = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.abortModal()
            } else if !mods.isDisjoint(with: [.command, .control, .option]), let key = event.charactersIgnoringModifiers?.lowercased() {
                reserved = isReserved(event.keyCode, mods, key)
                if !reserved {
                    defaults.set(Int(event.keyCode), forKey: "keyCode")
                    defaults.set(key, forKey: "key")
                    defaults.set(Int(mods.rawValue), forKey: "modifiers")
                }
                NSApp.stopModal()
            }
            return nil   // swallow every key so Return or Space can't press Cancel by accident
        }
        NSApp.activate()
        defer { returnToLastApp() }
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if reserved || !registerHotKey() {
            defaults.set(old.0, forKey: "keyCode")
            defaults.set(old.1, forKey: "key")
            defaults.set(old.2, forKey: "modifiers")
            registerHotKey()
            let taken = NSAlert()
            taken.messageText = "That shortcut is already taken"
            taken.informativeText = "macOS or every app uses it (like ⌘Space or ⌘C). DeClutter kept its previous shortcut; try another combination."
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

    func carbonModifiers(_ mods: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if mods.contains(.command) { carbon |= cmdKey }
        if mods.contains(.control) { carbon |= controlKey }
        if mods.contains(.option) { carbon |= optionKey }
        if mods.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    @discardableResult func registerHotKey() -> Bool {
        let mods = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "modifiers")))
        return RegisterEventHotKey(UInt32(defaults.integer(forKey: "keyCode")), UInt32(carbonModifiers(mods)),
                                   EventHotKeyID(signature: OSType(0x4443_4C52), id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
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
