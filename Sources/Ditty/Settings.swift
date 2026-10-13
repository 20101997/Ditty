import AppKit
import Carbon.HIToolbox

/// User options, stored in UserDefaults. Defaults mirror Ditto's.
enum S {
    private static let d = UserDefaults.standard

    private static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }

    static var maxEntriesEnabled: Bool { get { bool("maxEntriesEnabled", true) } set { d.set(newValue, forKey: "maxEntriesEnabled") } }
    static var maxEntries: Int { get { int("maxEntries", 500) } set { d.set(max(1, newValue), forKey: "maxEntries") } }
    static var expireEnabled: Bool { get { bool("expireEnabled", false) } set { d.set(newValue, forKey: "expireEnabled") } }
    static var expireDays: Int { get { int("expireDays", 5) } set { d.set(max(1, newValue), forKey: "expireDays") } }

    static var hotKeyCode: Int { get { int("hotKeyCode", kVK_ANSI_Grave) } set { d.set(newValue, forKey: "hotKeyCode") } }
    static var hotKeyMods: Int { get { int("hotKeyMods", controlKey) } set { d.set(newValue, forKey: "hotKeyMods") } }

    static var linesPerRow: Int { get { int("linesPerRow", 2) } set { d.set(min(max(newValue, 1), 10), forKey: "linesPerRow") } }
    static var fontSize: Int { get { int("fontSize", 13) } set { d.set(min(max(newValue, 9), 24), forKey: "fontSize") } }
    static var transparency: Int { get { int("transparency", 0) } set { d.set(min(max(newValue, 0), 80), forKey: "transparency") } }
    static var alwaysOnTop: Bool { get { bool("alwaysOnTop", false) } set { d.set(newValue, forKey: "alwaysOnTop") } }
    static var showThumbnails: Bool { get { bool("showThumbnails", true) } set { d.set(newValue, forKey: "showThumbnails") } }
    static var darkTheme: Bool { get { bool("darkTheme", false) } set { d.set(newValue, forKey: "darkTheme") } }
    /// 0 = at caret, 1 = at mouse cursor, 2 = at previous position
    static var position: Int { get { int("position", 0) } set { d.set(newValue, forKey: "position") } }
    static var updateOrderOnPaste: Bool { get { bool("updateOrderOnPaste", true) } set { d.set(newValue, forKey: "updateOrderOnPaste") } }
    static var connected: Bool { get { bool("connected", true) } set { d.set(newValue, forKey: "connected") } }

    static var saveText: Bool { get { bool("saveText", true) } set { d.set(newValue, forKey: "saveText") } }
    static var saveRTF: Bool { get { bool("saveRTF", true) } set { d.set(newValue, forKey: "saveRTF") } }
    static var saveHTML: Bool { get { bool("saveHTML", true) } set { d.set(newValue, forKey: "saveHTML") } }
    static var saveImages: Bool { get { bool("saveImages", true) } set { d.set(newValue, forKey: "saveImages") } }
    static var saveFiles: Bool { get { bool("saveFiles", true) } set { d.set(newValue, forKey: "saveFiles") } }

    static var windowFrame: NSRect? {
        get { d.string(forKey: "windowFrame").map(NSRectFromString) }
        set { d.set(newValue.map(NSStringFromRect), forKey: "windowFrame") }
    }
    static var firstRunDone: Bool { get { bool("firstRunDone", false) } set { d.set(newValue, forKey: "firstRunDone") } }

    static var databasePath: String {
        if let p = ProcessInfo.processInfo.environment["DITTY_DB"] { return p }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ditty")
        return dir.appendingPathComponent("Ditty.db").path
    }
}

/// Colours taken from Ditto's default theme (Theme.cpp), plus its dark variant.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    private static var dark: Bool { S.darkTheme }

    static var border: NSColor { dark ? rgb(70, 70, 70) : rgb(204, 204, 204) }
    static var captionButtons: NSColor { dark ? rgb(70, 70, 70) : rgb(204, 204, 204) }
    static var captionBG: NSColor { dark ? rgb(45, 45, 45) : rgb(255, 255, 255) }
    static var captionText: NSColor { dark ? rgb(120, 120, 120) : rgb(191, 191, 191) }
    static var captionGlyph: NSColor { dark ? rgb(200, 200, 200) : rgb(110, 110, 110) }
    static var oddRow: NSColor { dark ? rgb(45, 45, 45) : rgb(255, 255, 255) }
    static var evenRow: NSColor { dark ? rgb(55, 55, 55) : rgb(243, 243, 243) }
    static var selectedRow: NSColor { dark ? rgb(90, 90, 90) : rgb(204, 204, 204) }
    static var text: NSColor { dark ? rgb(230, 230, 230) : rgb(0, 0, 0) }
    static var index: NSColor { dark ? rgb(130, 130, 130) : rgb(180, 180, 180) }
    static var windowBG: NSColor { dark ? rgb(38, 38, 38) : rgb(240, 240, 240) }
    static var searchBG: NSColor { dark ? rgb(30, 30, 30) : rgb(255, 255, 255) }
    static var placeholder: NSColor { dark ? rgb(140, 140, 140) : rgb(150, 150, 150) }
    static var searchHighlight: NSColor { rgb(255, 0, 0) }
    static var accent: NSColor { rgb(0, 120, 215) }

    static let captionSize: CGFloat = 25
    static let bottomBarHeight: CGFloat = 30
}

// MARK: - Closure-based target/action

final class Callback: NSObject {
    let f: (Any?) -> Void
    init(_ f: @escaping (Any?) -> Void) { self.f = f }
    @objc func call(_ sender: Any?) { f(sender) }
}

private var callbackKey: UInt8 = 0

extension NSControl {
    func onAction(_ f: @escaping () -> Void) {
        let cb = Callback { _ in f() }
        objc_setAssociatedObject(self, &callbackKey, cb, .OBJC_ASSOCIATION_RETAIN)
        target = cb
        action = #selector(Callback.call(_:))
    }
}

extension NSMenuItem {
    convenience init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [], enabled: Bool = true, checked: Bool = false, _ f: @escaping () -> Void) {
        self.init(title: title, action: #selector(Callback.call(_:)), keyEquivalent: key)
        let cb = Callback { _ in f() }
        objc_setAssociatedObject(self, &callbackKey, cb, .OBJC_ASSOCIATION_RETAIN)
        target = cb
        keyEquivalentModifierMask = mods
        isEnabled = enabled
        state = checked ? .on : .off
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
