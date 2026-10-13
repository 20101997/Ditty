import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var db: Database!
    private(set) var monitor: ClipboardMonitor!
    private(set) var quickPaste: QuickPasteController!
    private var statusItem: NSStatusItem!
    private var optionsWindow: OptionsWindowController?
    private var propertiesWindow: PropertiesWindowController?
    private var accessibilityExplained = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
            Icons.writeAppIcon(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1])
            exit(0)
        }

        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != NSRunningApplication.current }) {
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = makeMainMenu()
        db = Database(path: S.databasePath)
        quickPaste = QuickPasteController(db: db)
        monitor = ClipboardMonitor(db: db)
        monitor.onNewClip = { [weak self] id in
            self?.quickPaste.currentClipID = id
            self?.quickPaste.clipsChanged()
        }
        monitor.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.toolTip = "Ditty"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusIcon()
        registerHotKey()
        trim()

        if !S.firstRunDone {
            S.firstRunDone = true
            Paster.requestAccessibility()
            quickPaste.show()
        }
    }

    /// Opening Ditty again while it is running shows the popup, as launching Ditto twice does on Windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !(optionsWindow?.window?.isVisible ?? false), !(propertiesWindow?.window?.isVisible ?? false) {
            quickPaste?.show()
        }
        return false
    }

    // MARK: - Menu bar

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            quickPaste.toggle()
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hotKey = KeyNames.describe(keyCode: S.hotKeyCode, carbonModifiers: S.hotKeyMods)
        [
            NSMenuItem("Show Ditty    \(hotKey)") { [weak self] in self?.quickPaste.show() },
            .separator(),
            NSMenuItem("Options…") { [weak self] in self?.showOptions() },
            NSMenuItem(S.connected ? "Disconnect from Clipboard" : "Connect to Clipboard") { [weak self] in self?.toggleConnected() },
            NSMenuItem("Delete All Clips…") { [weak self] in self?.deleteAllClips() },
            .separator(),
            NSMenuItem("Exit") { NSApp.terminate(nil) },
        ].forEach(menu.addItem)
        return menu
    }

    private func updateStatusIcon() {
        statusItem.button?.image = Icons.statusIcon(connected: S.connected)
    }

    /// An accessory app shows no menu bar, but the Edit menu still supplies Cmd+C/V/X/A/Z to its text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit Ditty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)
        return main
    }

    // MARK: - Actions shared by the menus and windows

    private func registerHotKey() {
        let ok = HotKeyCenter.shared.register(id: 1, keyCode: S.hotKeyCode, carbonModifiers: S.hotKeyMods) { [weak self] in
            self?.quickPaste.toggle()
        }
        if !ok { NSLog("Ditty: could not register the activation hot key") }
    }

    private func trim() {
        db.trim(maxEntries: S.maxEntriesEnabled ? S.maxEntries : nil, expireDays: S.expireEnabled ? S.expireDays : nil)
    }

    func settingsChanged() {
        registerHotKey()
        trim()
        quickPaste.applySettings()
    }

    func toggleConnected() {
        S.connected.toggle()
        updateStatusIcon()
    }

    func showOptions() {
        quickPaste.hide(returnFocus: false)
        if optionsWindow == nil { optionsWindow = OptionsWindowController(db: db) }
        NSApp.activate(ignoringOtherApps: true)
        optionsWindow?.showWindow(nil)
        optionsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func showProperties(for id: Int64) {
        guard let clip = db.clip(id) else { return }
        propertiesWindow?.close()
        propertiesWindow = PropertiesWindowController(db: db, clip: clip)
        NSApp.activate(ignoringOtherApps: true)
        propertiesWindow?.showWindow(nil)
        propertiesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func deleteAllClips() {
        quickPaste.hide(returnFocus: false)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete all clips?"
        alert.informativeText = "This removes every saved copy except sticky clips, clips marked Never Auto Delete and clips inside groups. It cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            db.deleteAllDisposable()
            quickPaste.clipsChanged()
        }
    }

    /// Without the Accessibility permission macOS drops the simulated Cmd+V, so say so instead of failing silently.
    func explainAccessibility() {
        guard !accessibilityExplained else { return }
        accessibilityExplained = true
        let alert = NSAlert()
        alert.messageText = "Ditty needs the Accessibility permission to paste for you"
        alert.informativeText = "The clip is on your clipboard, so you can press ⌘V yourself right now.\n\nTo let Ditty paste automatically, turn on Ditty under System Settings → Privacy & Security → Accessibility."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Paster.requestAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Snapshot

    /// Renders the popup with sample clips into a PNG, using a throwaway database.
    private func snapshot(to path: String) {
        let temp = NSTemporaryDirectory() + "ditty-snapshot-\(ProcessInfo.processInfo.processIdentifier).db"
        db = Database(path: temp)
        let samples = ["search", "paste plain text", "view copied images", "send clip to network computers",
                       "compare clips in diff app", "copy", "paste"]
        for text in samples {
            db.addClip(text: text, formats: [ClipFormat(type: ClipFormat.text, data: Data(text.utf8))], crc: Database.crc(Data(text.utf8)))
        }
        quickPaste = QuickPasteController(db: db)
        quickPaste.currentClipID = db.fetch(parent: Database.rootID, search: "").last?.id
        quickPaste.snapshot(to: path)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temp + suffix) }
    }
}
