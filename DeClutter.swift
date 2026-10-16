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
    var askedForAccessibility = false
    let defaults = UserDefaults.standard

    var isDecluttered: Bool {
        hidden.contains { $0.isHidden && !$0.isTerminated } || minimized.contains(where: isMinimized)
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

    // Quitting never leaves apps stranded.
    func applicationWillTerminate(_ note: Notification) {
        if isDecluttered { restore(hidden) }
    }

    // Clicking the Dock icon (or `open -a DeClutter`, e.g. from Spotlight or Raycast) toggles too.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }

    @objc func statusClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
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
            "macOS settings to hide icons. To reorder them, hold ⌘ and drag them in the menu bar."
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
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func toggle() {
        guard !isDecluttered else { return restore(hidden) }
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
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            guard current == generation else { return }
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
    // one slow app no longer holds up the others, and DeClutter stays responsive.
    func unminimize(_ windows: [AXUIElement]) {
        let byApp = Dictionary(grouping: windows) { window -> pid_t in
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            return pid
        }
        for group in byApp.values {
            DispatchQueue.global(qos: .userInteractive).async {
                group.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            }
        }
    }

    func restore(_ apps: [NSRunningApplication]) {
        generation += 1
        // macOS only lets the active app hand focus to another, so take it first. It must come before unhide(): that
        // request is asynchronous, and activating right after it left every app hidden.
        NSApp.activate()
        apps.forEach { $0.unhide() }
        unminimize(minimized)
        minimized = []
        (frontBeforeDeclutter ?? lastFront)?.activate()   // lastFront when nothing was decluttered (Restore Everything)
        frontBeforeDeclutter = nil
        hidden = []
        updateIcon()
    }

    // Minimizing other apps' windows needs Accessibility permission. macOS asks at most once per launch; until it's
    // granted, DeClutter hides instead. The grant survives rebuilds because build.sh signs with a local certificate.
    var hasAccessibility: Bool {
        defer { askedForAccessibility = true }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": !askedForAccessibility] as CFDictionary)
    }

    func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)   // a frozen app can't stall DeClutter for long
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
        defer { lastFront?.activate() }   // once the dialog closes, back to the app the person was in
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
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.abortModal()
            } else if !mods.isDisjoint(with: [.command, .control, .option]), let key = event.charactersIgnoringModifiers?.lowercased() {
                defaults.set(Int(event.keyCode), forKey: "keyCode")
                defaults.set(key, forKey: "key")
                defaults.set(Int(mods.rawValue), forKey: "modifiers")
                NSApp.stopModal()
            }
            return nil   // swallow every key so Return or Space can't press Cancel by accident
        }
        NSApp.activate()
        defer { lastFront?.activate() }   // once the dialogs close, back to the app the person was in
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if !registerHotKey() {
            defaults.set(old.0, forKey: "keyCode")
            defaults.set(old.1, forKey: "key")
            defaults.set(old.2, forKey: "modifiers")
            registerHotKey()
            let taken = NSAlert()
            taken.messageText = "Another app already uses that shortcut"
            taken.informativeText = "DeClutter kept its previous shortcut. Try a different combination."
            taken.runModal()
        }
    }

    @discardableResult func registerHotKey() -> Bool {
        let mods = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "modifiers")))
        var carbon = 0
        if mods.contains(.command) { carbon |= cmdKey }
        if mods.contains(.control) { carbon |= controlKey }
        if mods.contains(.option) { carbon |= optionKey }
        if mods.contains(.shift) { carbon |= shiftKey }
        return RegisterEventHotKey(UInt32(defaults.integer(forKey: "keyCode")), UInt32(carbon),
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
        try? login.status == .enabled ? login.unregister() : login.register()
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
