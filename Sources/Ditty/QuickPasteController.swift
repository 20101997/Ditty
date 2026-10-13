import AppKit
import Carbon.HIToolbox

final class QuickPasteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let panel: QuickPastePanel
    private let chrome = ChromeView(frame: NSRect(x: 0, y: 0, width: 365, height: 312))
    private let tableView = ClipTableView()
    private let db: Database
    private let descriptionWindow = DescriptionWindow()
    private let thumbnails = NSCache<NSNumber, NSImage>()

    private var clips: [Clip] = []
    private var currentGroup = Database.rootID
    private var previousApp: NSRunningApplication?
    private var rolledUpFrom: NSRect?
    /// Set while Ditty itself takes focus away (a prompt, a menu), so the popup is not dismissed for it.
    private var busy = false
    /// The clip currently on the system clipboard, shown with Ditto's blue bar.
    var currentClipID: Int64? { didSet { redrawRows() } }

    private var searchField: NSTextField { chrome.searchBox.field }
    private var search: String { searchField.stringValue }
    private static let normalMinSize = NSSize(width: 170, height: 120)

    init(db: Database) {
        self.db = db
        panel = QuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 365, height: 312),
                                styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()

        panel.contentView = chrome
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = Self.normalMinSize
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }

        chrome.scrollView.documentView = tableView
        chrome.scrollView.hasVerticalScroller = true
        chrome.scrollView.autohidesScrollers = true
        chrome.scrollView.borderType = .noBorder

        searchField.delegate = self
        chrome.searchBox.onClear = { [weak self] in self?.setSearch("") }
        chrome.caption.onClose = { [weak self] in self?.hide() }
        chrome.caption.onRollUp = { [weak self] in self?.toggleRollUp() }
        chrome.moreButton.onClick = { [weak self] in
            guard let self else { return }
            self.popUp(self.contextMenu(forRow: nil), from: self.chrome.moreButton)
        }
        chrome.groupButton.onClick = { [weak self] in
            guard let self else { return }
            if self.currentGroup != Database.rootID {
                self.leaveGroup()
            } else {
                let menu = NSMenu()
                menu.autoenablesItems = false
                self.groupMenuItems(selection: self.selectedClips).forEach(menu.addItem)
                self.popUp(menu, from: self.chrome.groupButton)
            }
        }

        // Remember the app the user is working in, so a paste can be sent back to it.
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current {
                self?.previousApp = app
            }
        }

        if let saved = S.windowFrame, saved.width >= Self.normalMinSize.width, saved.height >= Self.normalMinSize.height {
            panel.setFrame(saved, display: false)
        }
        applySettings()
    }

    // MARK: - Showing and hiding

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible, panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        if rolledUpFrom != nil { toggleRollUp() }
        currentGroup = Database.rootID
        searchField.stringValue = ""
        reload()
        select(row: 0)

        if !(panel.isVisible && S.alwaysOnTop) {
            positionWindow()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    /// `returnFocus` hands the keyboard back to the previous app when Ditty itself had become active.
    func hide(returnFocus: Bool = true) {
        descriptionWindow.hide()
        panel.orderOut(nil)
        if returnFocus, NSApp.isActive { previousApp?.activate() }
    }

    private func positionWindow() {
        let size = panel.frame.size
        var anchor: NSPoint
        var caret: NSRect?
        switch S.position {
        case 2:
            return
        case 0:
            caret = Paster.caretRect()
            fallthrough
        default:
            if let caret {
                anchor = NSPoint(x: caret.minX, y: caret.minY - 2)
            } else {
                anchor = NSEvent.mouseLocation
            }
        }
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // Opens below the caret; flips above it when there is no room underneath.
        if let caret, anchor.y - size.height < visible.minY { anchor.y = caret.maxY + 2 + size.height }
        let x = min(max(anchor.x, visible.minX), visible.maxX - size.width)
        let top = min(max(anchor.y, visible.minY + size.height), visible.maxY)
        panel.setFrameOrigin(NSPoint(x: x, y: top - size.height))
    }

    func windowDidResignKey(_ notification: Notification) {
        if !S.alwaysOnTop, !busy { hide() }
    }

    func windowDidResize(_ notification: Notification) {
        fitColumn()
        saveFrame()
    }

    private func fitColumn() {
        tableView.tableColumns.first?.width = chrome.scrollView.contentSize.width
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        if panel.isVisible, rolledUpFrom == nil { S.windowFrame = panel.frame }
    }

    private func toggleRollUp() {
        if let full = rolledUpFrom {
            rolledUpFrom = nil
            panel.minSize = Self.normalMinSize
            panel.setFrame(full, display: true)
        } else {
            let full = panel.frame
            rolledUpFrom = full
            let width = Theme.captionSize + 2
            panel.minSize = NSSize(width: width, height: 80)
            panel.setFrame(NSRect(x: full.maxX - width, y: full.minY, width: width, height: full.height), display: true)
        }
        chrome.caption.rolledUp = rolledUpFrom != nil
    }

    // MARK: - Settings

    func applySettings() {
        panel.appearance = NSAppearance(named: S.darkTheme ? .darkAqua : .aqua)
        panel.alphaValue = 1 - CGFloat(S.transparency) / 100
        tableView.rowHeight = ClipCellView.rowHeight
        tableView.backgroundColor = Theme.windowBG
        chrome.scrollView.backgroundColor = Theme.windowBG
        updateSearchBox()
        thumbnails.removeAllObjects()
        chrome.needsDisplay = true
        chrome.caption.needsDisplay = true
        chrome.groupButton.needsDisplay = true
        chrome.moreButton.needsDisplay = true
        reload()
    }

    private func updateSearchBox() {
        var placeholder = "Search"
        if currentGroup != Database.rootID, let group = db.clip(currentGroup) { placeholder = "Search  ·  \(group.text)" }
        chrome.searchBox.applyTheme(placeholder: placeholder)
        chrome.searchBox.active = !search.isEmpty
        chrome.inGroup = currentGroup != Database.rootID
    }

    // MARK: - Data

    /// Reloads the list, keeping the selection on the same clips where they are still shown.
    func reload() {
        let selectedIDs = Set(selectedClips.map(\.id))
        clips = db.fetch(parent: currentGroup, search: search)
        fitColumn()
        tableView.reloadData()
        let rows = IndexSet(clips.indices.filter { selectedIDs.contains(clips[$0].id) })
        if !rows.isEmpty { tableView.selectRowIndexes(rows, byExtendingSelection: false) }
        updateSearchBox()
        updateDescription()
    }

    /// Called when a new copy arrives while the popup is open.
    func clipsChanged() {
        if panel.isVisible { reload() }
    }

    private var selectedClips: [Clip] {
        tableView.selectedRowIndexes.filter { $0 < clips.count }.map { clips[$0] }
    }

    private func select(row: Int, extend: Bool = false) {
        guard !clips.isEmpty else { return }
        let r = min(max(row, 0), clips.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: extend)
        tableView.scrollRowToVisible(r)
    }

    private func setSearch(_ text: String) {
        searchField.stringValue = text
        reload()
        select(row: 0)
    }

    private func redrawRows() {
        tableView.enumerateAvailableRowViews { rowView, row in
            for case let cell as ClipCellView in rowView.subviews {
                cell.marked = row < self.clips.count && self.clips[row].id == self.currentClipID
                cell.needsDisplay = true
            }
        }
    }

    private func thumbnail(for clip: Clip) -> NSImage? {
        guard S.showThumbnails, clip.hasImage else { return nil }
        if let cached = thumbnails.object(forKey: NSNumber(value: clip.id)) { return cached }
        guard let data = db.data(clip.id, format: ClipFormat.png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails.setObject(image, forKey: NSNumber(value: clip.id))
        return image
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ClipCellView ?? {
            let c = ClipCellView()
            c.identifier = id
            return c
        }()
        let clip = clips[row]
        cell.clip = clip
        cell.row = row
        cell.search = search
        cell.marked = clip.id == currentClipID
        cell.thumbnail = thumbnail(for: clip)
        cell.tableView = tableView
        cell.needsDisplay = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        redrawRows()
        updateDescription()
    }

    @objc private func doubleClicked() {
        if tableView.clickedRow >= 0 { paste(selectedClips) }
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
        select(row: 0)
    }

    // MARK: - Keyboard

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3, kVK_ANSI_5: 4,
        kVK_ANSI_6: 5, kVK_ANSI_7: 6, kVK_ANSI_8: 7, kVK_ANSI_9: 8, kVK_ANSI_0: 9,
    ]

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)
        let row = tableView.selectedRowIndexes.last ?? -1
        let page = max(1, Int(chrome.scrollView.contentSize.height / tableView.rowHeight) - 1)
        let shortcut = mods == .command || mods == .control

        switch code {
        case kVK_Escape:
            if !search.isEmpty { setSearch("") } else { hide() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .option { showProperties() } else { paste(selectedClips, plainText: mods == .shift) }
        case kVK_UpArrow: select(row: row - 1, extend: mods == .shift)
        case kVK_DownArrow: select(row: row + 1, extend: mods == .shift)
        case kVK_PageUp: select(row: row - page)
        case kVK_PageDown: select(row: row + page)
        case kVK_Home where search.isEmpty: select(row: 0)
        case kVK_End where search.isEmpty: select(row: clips.count - 1)
        case kVK_ForwardDelete: deleteSelected()
        case kVK_Delete where mods == .command: deleteSelected()
        case kVK_Delete where search.isEmpty && currentGroup != Database.rootID: leaveGroup()
        case kVK_F3: toggleDescription()
        case kVK_F7: newGroup(moving: [])
        case kVK_ANSI_Comma where mods == .command: AppDelegate.shared.showOptions()
        case kVK_ANSI_C where mods == .command:
            // With text selected in the search box Cmd+C copies that text, as usual.
            if let editor = searchField.currentEditor(), editor.selectedRange.length > 0 { return false }
            copyToClipboard(selectedClips)
        case _ where shortcut && Self.digitKeys[code] != nil:
            let n = Self.digitKeys[code]!
            if n < clips.count { paste([clips[n]]) }
        default:
            return false
        }
        return true
    }

    // MARK: - Actions

    private func copyToClipboard(_ items: [Clip], plainText: Bool = false, transform: ((String) -> String)? = nil) {
        let real = items.filter { !$0.isGroup }
        guard !real.isEmpty, Paster.load(real, db: db, plainText: plainText, transform: transform) else { return }
        AppDelegate.shared.monitor.skipCurrentContents()
        for clip in real { db.markPasted(clip.id, bumpOrder: S.updateOrderOnPaste) }
        currentClipID = real.count == 1 ? real[0].id : nil
    }

    /// Ditto's main action: put the clip on the clipboard and paste it into the app you came from.
    func paste(_ items: [Clip], plainText: Bool = false, transform: ((String) -> String)? = nil) {
        if items.count == 1, items[0].isGroup {
            enterGroup(items[0].id)
            return
        }
        guard items.contains(where: { !$0.isGroup }) else { return }
        copyToClipboard(items, plainText: plainText, transform: transform)

        let wasActive = NSApp.isActive
        if S.alwaysOnTop {
            // Stay on screen but hand keyboard focus back, so the paste lands in the other app.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
            if wasActive { previousApp?.activate() }
            reload()
        } else {
            hide()
        }
        guard Paster.canSendKeys else {
            AppDelegate.shared.explainAccessibility()
            return
        }
        // Give the other app a moment to take focus back when Ditty had been activated.
        let delay = wasActive ? 0.25 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Paster.sendPaste() }
    }

    private func deleteSelected() {
        let rows = tableView.selectedRowIndexes
        guard let first = rows.first else { return }
        db.delete(selectedClips.map(\.id))
        tableView.deselectAll(nil)
        reload()
        select(row: min(first, clips.count - 1))
    }

    private func enterGroup(_ id: Int64) {
        currentGroup = id
        searchField.stringValue = ""
        tableView.deselectAll(nil)
        reload()
        select(row: 0)
    }

    private func leaveGroup() {
        let leaving = currentGroup
        currentGroup = db.clip(currentGroup)?.parentID ?? Database.rootID
        tableView.deselectAll(nil)
        reload()
        select(row: clips.firstIndex { $0.id == leaving } ?? 0)
    }

    private func newGroup(moving items: [Clip]) {
        guard let name = prompt(title: "New Group", message: "Group name:", value: "") else { return }
        let id = db.createGroup(name: name, parent: currentGroup)
        db.setParent(items.map(\.id), id)
        reload()
    }

    private func move(_ items: [Clip], to group: Int64) {
        db.setParent(items.map(\.id), group)
        tableView.deselectAll(nil)
        reload()
        select(row: 0)
    }

    private func showProperties() {
        guard let clip = selectedClips.first else { return }
        hide(returnFocus: false)
        AppDelegate.shared.showProperties(for: clip.id)
    }

    private func toggleDescription() {
        if descriptionWindow.isVisible { descriptionWindow.hide() } else { updateDescription(force: true) }
    }

    private func updateDescription(force: Bool = false) {
        guard force || descriptionWindow.isVisible else { return }
        guard let clip = selectedClips.first, panel.isVisible else {
            descriptionWindow.hide()
            return
        }
        let image = clip.hasImage ? db.data(clip.id, format: ClipFormat.png).flatMap(NSImage.init(data:)) : nil
        descriptionWindow.show(text: clip.isGroup ? clip.text : db.fullText(clip.id), image: image, beside: panel)
    }

    /// Asks for a line of text. Ditty has to become the active app for the prompt, so the popup is put back afterwards.
    private func prompt(title: String, message: String, value: String) -> String? {
        busy = true
        defer { busy = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.window.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        previousApp?.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && !text.isEmpty ? text : nil
    }

    // MARK: - Menus

    private func popUp(_ menu: NSMenu, from view: NSView) {
        busy = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 2), in: view)
        busy = false
    }

    private func groupMenuItems(selection: [Clip]) -> [NSMenuItem] {
        let groups = db.groups()
        let hasSelection = !selection.isEmpty
        var moveItems = [NSMenuItem("Main List", enabled: hasSelection && currentGroup != Database.rootID) { [weak self] in
            self?.move(selection, to: Database.rootID)
        }]
        if !groups.isEmpty { moveItems.append(.separator()) }
        moveItems += groups.map { g in
            NSMenuItem(g.text, enabled: hasSelection && !selection.contains { $0.id == g.id }) { [weak self] in self?.move(selection, to: g.id) }
        }
        var viewItems = [NSMenuItem("All Clips", checked: currentGroup == Database.rootID) { [weak self] in self?.enterGroup(Database.rootID) }]
        if !groups.isEmpty { viewItems.append(.separator()) }
        viewItems += groups.map { g in
            NSMenuItem(g.text, checked: currentGroup == g.id) { [weak self] in self?.enterGroup(g.id) }
        }
        return [
            NSMenuItem("New Group…") { [weak self] in self?.newGroup(moving: []) },
            NSMenuItem("New Group From Selection…", enabled: hasSelection) { [weak self] in self?.newGroup(moving: selection) },
            .submenu("Move to Group", moveItems),
            .submenu("View Group", viewItems),
        ]
    }

    /// The right-click menu, also shown by the "..." button. `row` nil means "use the current selection".
    private func contextMenu(forRow row: Int?) -> NSMenu {
        if let row, row >= 0, !tableView.selectedRowIndexes.contains(row) { select(row: row) }
        let selection = selectedClips
        let clip = selection.first
        let hasClip = clip != nil
        let isText = hasClip && !selection.contains { $0.isGroup }

        func special(_ title: String, _ transform: @escaping (String) -> String) -> NSMenuItem {
            NSMenuItem(title, enabled: isText) { [weak self] in self?.paste(selection, transform: transform) }
        }
        func option(_ title: String, checked: Bool, _ change: @escaping () -> Void) -> NSMenuItem {
            NSMenuItem(title, checked: checked) {
                change()
                AppDelegate.shared.settingsChanged()
            }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [NSMenuItem] = [
            NSMenuItem("Paste", enabled: hasClip) { [weak self] in self?.paste(selection) },
            .submenu("Paste Special", [
                NSMenuItem("Plain Text Only", enabled: isText) { [weak self] in self?.paste(selection, plainText: true) },
                .separator(),
                special("UPPER CASE") { $0.uppercased() },
                special("lower case") { $0.lowercased() },
                special("Capitalize") { $0.capitalized },
                special("Sentence case", TextTransform.sentenceCase),
                special("Camel Case", TextTransform.camelCase),
                special("Slugify", TextTransform.slugify),
                .separator(),
                special("Remove Line Feeds", TextTransform.removeLineFeeds),
                special("Paste + One Line Feed") { $0 + "\n" },
                special("Paste + Two Line Feeds") { $0 + "\n\n" },
                special("Trim White Space") { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                special("Add Current Time", TextTransform.addCurrentTime),
                special("Typoglycemia", TextTransform.typoglycemia),
            ]),
            NSMenuItem("Copy to Clipboard", enabled: isText) { [weak self] in self?.copyToClipboard(selection) },
            .separator(),
            .submenu("Groups", groupMenuItems(selection: selection)),
            .submenu("Clip Order", [
                NSMenuItem("Move to Top", enabled: hasClip) { [weak self] in
                    selection.reversed().forEach { self?.db.moveToTop($0.id) }
                    self?.reload()
                },
                .separator(),
                NSMenuItem("Make Top Sticky Clip", enabled: hasClip) { [weak self] in
                    selection.reversed().forEach { self?.db.setSticky($0.id, .top) }
                    self?.reload()
                },
                NSMenuItem("Make Last Sticky Clip", enabled: hasClip) { [weak self] in
                    selection.forEach { self?.db.setSticky($0.id, .last) }
                    self?.reload()
                },
                NSMenuItem("Remove Sticky Setting", enabled: selection.contains { $0.isSticky }) { [weak self] in
                    selection.forEach { self?.db.setSticky($0.id, .none) }
                    self?.reload()
                },
            ]),
            NSMenuItem("Never Auto Delete", enabled: isText, checked: clip?.dontAutoDelete ?? false) { [weak self] in
                let value = !(clip?.dontAutoDelete ?? false)
                selection.forEach { self?.db.setDontAutoDelete($0.id, value) }
                self?.reload()
            },
            NSMenuItem("View Full Description", enabled: hasClip) { [weak self] in self?.toggleDescription() },
            NSMenuItem("Properties…", enabled: hasClip) { [weak self] in self?.showProperties() },
            NSMenuItem("Delete Clip", enabled: hasClip) { [weak self] in self?.deleteSelected() },
            .separator(),
            .submenu("Quick Options", [
                .submenu("Lines Per Row", (1...5).map { n in option("\(n)", checked: S.linesPerRow == n) { S.linesPerRow = n } }),
                .submenu("Font Size", [11, 12, 13, 14, 16, 18].map { n in option("\(n)", checked: S.fontSize == n) { S.fontSize = n } }),
                .submenu("Transparency", [0, 5, 10, 15, 20, 25, 30, 40].map { n in
                    option(n == 0 ? "None" : "\(n)%", checked: S.transparency == n) { S.transparency = n }
                }),
                .submenu("Positioning", ["At Caret", "At Cursor", "At Previous Position"].enumerated().map { i, title in
                    option(title, checked: S.position == i) { S.position = i }
                }),
                .separator(),
                option("Always on Top", checked: S.alwaysOnTop) { S.alwaysOnTop.toggle() },
                option("Show Thumbnails", checked: S.showThumbnails) { S.showThumbnails.toggle() },
                option("Dark Theme", checked: S.darkTheme) { S.darkTheme.toggle() },
            ]),
            NSMenuItem("Options…") { AppDelegate.shared.showOptions() },
            .separator(),
            NSMenuItem(S.connected ? "Disconnect from Clipboard" : "Connect to Clipboard") { AppDelegate.shared.toggleConnected() },
            NSMenuItem("Exit") { NSApp.terminate(nil) },
        ]
        items.forEach(menu.addItem)
        return menu
    }

    // MARK: - Snapshot (used by --snapshot to check the look without screen-recording permission)

    func snapshot(to path: String) {
        panel.setFrame(NSRect(x: 0, y: 0, width: 365, height: 312), display: false)
        currentGroup = Database.rootID
        reload()
        select(row: 0)
        chrome.layoutSubtreeIfNeeded()
        chrome.display()
        guard let rep = chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds) else { return }
        chrome.cacheDisplay(in: chrome.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
