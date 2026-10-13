import AppKit

/// The popup: a borderless panel that takes keyboard input without activating Ditty,
/// so the app being pasted into stays frontmost.
final class QuickPastePanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// A small custom-drawn button.
final class GlyphButton: NSView {
    var drawGlyph: ((NSRect) -> Void)?
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawGlyph?(bounds) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Ditto's caption: a strip down the right edge with close and roll-up buttons and the rotated title.
final class CaptionView: NSView {
    var onClose: (() -> Void)?
    var onRollUp: (() -> Void)?
    var rolledUp = false { didSet { needsDisplay = true } }

    private let buttonSize = Theme.captionSize

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.captionBG.setFill()
        bounds.fill()
        Theme.captionButtons.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: buttonSize * 2 + 4).fill()

        Theme.captionGlyph.setStroke()
        let cx = bounds.midX
        let close = NSBezierPath()
        close.lineWidth = 1
        let c = NSPoint(x: cx, y: buttonSize / 2 + 2)
        close.move(to: NSPoint(x: c.x - 5, y: c.y - 5)); close.line(to: NSPoint(x: c.x + 5, y: c.y + 5))
        close.move(to: NSPoint(x: c.x + 5, y: c.y - 5)); close.line(to: NSPoint(x: c.x - 5, y: c.y + 5))
        close.stroke()

        // Double chevron: points right to roll the window up into the caption, left to bring it back.
        let chevrons = NSBezierPath()
        chevrons.lineWidth = 1
        let m = NSPoint(x: cx, y: buttonSize * 1.5 + 2)
        let dir: CGFloat = rolledUp ? -1 : 1
        for offset in [-3.0, 2.0] as [CGFloat] {
            let x = m.x + offset * dir
            chevrons.move(to: NSPoint(x: x - 2 * dir, y: m.y - 4))
            chevrons.line(to: NSPoint(x: x + 2 * dir, y: m.y))
            chevrons.line(to: NSPoint(x: x - 2 * dir, y: m.y + 4))
        }
        chevrons.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: Theme.captionText]
        let title = NSAttributedString(string: "Ditty", attributes: attrs)
        let size = title.size()
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: bounds.midX + size.height / 2, yBy: buttonSize * 2 + 12)
        t.rotate(byDegrees: 90)
        t.concat()
        title.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= buttonSize + 2 {
            onClose?()
        } else if p.y <= buttonSize * 2 + 4 {
            onRollUp?()
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// The search box in the bottom bar. Like Ditto's, it only looks like an edit box once it holds text.
final class SearchBox: NSView {
    let field = NSTextField()
    private let clearButton = GlyphButton()
    var onClear: (() -> Void)?

    var active = false {
        didSet {
            clearButton.isHidden = !active
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
        clearButton.isHidden = true
        clearButton.drawGlyph = { r in
            Theme.placeholder.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1
            p.move(to: NSPoint(x: r.midX - 4, y: r.midY - 4)); p.line(to: NSPoint(x: r.midX + 4, y: r.midY + 4))
            p.move(to: NSPoint(x: r.midX + 4, y: r.midY - 4)); p.line(to: NSPoint(x: r.midX - 4, y: r.midY + 4))
            p.stroke()
        }
        clearButton.onClick = { [weak self] in self?.onClear?() }
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(placeholder: String) {
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.placeholder,
        ])
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let h = field.intrinsicContentSize.height
        field.frame = NSRect(x: 4, y: (bounds.height - h) / 2, width: bounds.width - 26, height: h)
        clearButton.frame = NSRect(x: bounds.width - 22, y: 0, width: 22, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        Theme.searchBG.setFill()
        bounds.fill()
        Theme.accent.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

/// The window's content: border, list, bottom bar and caption, laid out the way Ditto does.
final class ChromeView: NSView {
    let scrollView = NSScrollView()
    let caption = CaptionView()
    let groupButton = GlyphButton()
    let searchBox = SearchBox(frame: .zero)
    let moreButton = GlyphButton()
    /// When set the group button shows a "back" arrow instead of the groups glyph.
    var inGroup = false { didSet { groupButton.needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [scrollView, caption, groupButton, searchBox, moreButton].forEach(addSubview)

        groupButton.drawGlyph = { [weak self] r in
            Theme.captionGlyph.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1
            if self?.inGroup == true {
                p.move(to: NSPoint(x: r.midX + 5, y: r.midY)); p.line(to: NSPoint(x: r.midX - 5, y: r.midY))
                p.move(to: NSPoint(x: r.midX - 1, y: r.midY - 4)); p.line(to: NSPoint(x: r.midX - 5, y: r.midY))
                p.line(to: NSPoint(x: r.midX - 1, y: r.midY + 4))
            } else {
                let x = r.midX - 6.5, y = r.midY - 6.5
                p.move(to: NSPoint(x: x, y: y + 2)); p.line(to: NSPoint(x: x + 9, y: y + 2))
                p.line(to: NSPoint(x: x + 9, y: y)); p.line(to: NSPoint(x: x + 13, y: y))
                p.line(to: NSPoint(x: x + 13, y: y + 13)); p.line(to: NSPoint(x: x, y: y + 13))
                p.close()
            }
            p.stroke()
        }
        moreButton.drawGlyph = { r in
            Theme.captionGlyph.setFill()
            for dx in [-5.0, 0.0, 5.0] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: r.midX + dx - 1.25, y: r.midY - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
        layoutChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChrome()
    }

    private func layoutChrome() {
        let w = bounds.width, h = bounds.height
        let cap = Theme.captionSize, bar = Theme.bottomBarHeight
        let listWidth = max(0, w - 2 - cap)
        caption.frame = NSRect(x: w - 1 - cap, y: 1, width: cap, height: h - 2)
        scrollView.frame = NSRect(x: 1, y: 1, width: listWidth, height: max(0, h - 2 - bar))
        let barY = h - 1 - bar
        groupButton.frame = NSRect(x: 6, y: barY + 4, width: 24, height: 22)
        searchBox.frame = NSRect(x: 34, y: barY + 4, width: max(0, listWidth - 34 - 34), height: 22)
        moreButton.frame = NSRect(x: 1 + listWidth - 32, y: barY + 4, width: 28, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBG.setFill()
        bounds.fill()
        Theme.border.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

final class ClipTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    // The search box keeps keyboard focus; the list is driven from the panel's key handler.
    override var acceptsFirstResponder: Bool { false }
}

/// One row of the list, drawn to match Ditto: index gutter, separator, then the clip.
final class ClipCellView: NSView {
    static let gutter: CGFloat = 13

    var clip: Clip?
    var row = 0
    var search = ""
    var marked = false
    var thumbnail: NSImage?
    weak var tableView: NSTableView?

    override var isFlipped: Bool { true }

    static var font: NSFont { NSFont.systemFont(ofSize: CGFloat(S.fontSize)) }
    static var rowHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(S.linesPerRow)) + 6
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.index]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let clip else { return }
        let selected = tableView?.selectedRowIndexes.contains(row) ?? false
        (selected ? Theme.selectedRow : (row % 2 == 0 ? Theme.oddRow : Theme.evenRow)).setFill()
        bounds.fill()

        if marked {
            Theme.accent.setFill()
            NSRect(x: 2, y: 0, width: 2, height: bounds.height).fill()
        }
        if row < 10 {
            let index = NSAttributedString(string: "\(row + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 7), .foregroundColor: Theme.index,
            ])
            index.draw(at: NSPoint(x: Self.gutter - 2 - index.size().width, y: 2))
        }
        Theme.border.setFill()
        NSRect(x: Self.gutter, y: 0, width: 1, height: bounds.height).fill()

        var content = NSRect(x: Self.gutter + 4, y: 2, width: bounds.width - Self.gutter - 8, height: bounds.height - 4)

        if clip.isSticky, let pin = Self.symbol("pin.fill", size: 9) {
            let s = pin.size
            pin.draw(in: NSRect(x: bounds.width - s.width - 5, y: 4, width: s.width, height: s.height))
            content.size.width -= s.width + 6
        }
        if clip.isGroup, let folder = Self.symbol("folder.fill", size: 12) {
            let s = folder.size
            folder.draw(in: NSRect(x: content.minX, y: content.minY + 1, width: s.width, height: s.height))
            content.origin.x += s.width + 5
            content.size.width -= s.width + 5
        }
        if let thumbnail, thumbnail.size.height > 0 {
            let h = content.height
            let w = min(content.width, thumbnail.size.width * h / thumbnail.size.height)
            thumbnail.draw(in: NSRect(x: content.minX, y: content.minY, width: w, height: h),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return
        }

        let shown = String(clip.text.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\t", with: "    ")
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = S.linesPerRow == 1 ? .byTruncatingTail : .byWordWrapping
        let text = NSMutableAttributedString(string: shown, attributes: [
            .font: clip.isGroup ? NSFont.boldSystemFont(ofSize: CGFloat(S.fontSize)) : Self.font,
            .foregroundColor: Theme.text,
            .paragraphStyle: style,
        ])
        if !search.isEmpty {
            let ns = shown as NSString
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let found = ns.range(of: search, options: .caseInsensitive, range: range)
                guard found.location != NSNotFound else { break }
                text.addAttribute(.foregroundColor, value: Theme.searchHighlight, range: found)
                range = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
            }
        }
        text.draw(with: content, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Ditto's F3 "description" window: the whole clip, shown beside the list.
final class DescriptionWindow {
    let panel: NSPanel
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: panel.contentLayoutRect)
        content.wantsLayer = true
        content.layer?.borderWidth = 1
        panel.contentView = content

        scroll.frame = content.bounds.insetBy(dx: 1, dy: 1)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.frame = scroll.bounds
        scroll.documentView = textView
        content.addSubview(scroll)

        imageView.frame = content.bounds.insetBy(dx: 6, dy: 6)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyDown
        content.addSubview(imageView)
    }

    func show(text: String, image: NSImage?, beside parent: NSWindow) {
        panel.contentView?.layer?.backgroundColor = Theme.windowBG.cgColor
        panel.contentView?.layer?.borderColor = Theme.border.cgColor
        imageView.isHidden = image == nil
        scroll.isHidden = image != nil
        imageView.image = image
        textView.string = String(text.prefix(200_000))
        textView.font = NSFont.systemFont(ofSize: CGFloat(S.fontSize))
        textView.textColor = Theme.text
        textView.scrollToBeginningOfDocument(nil)

        let size = panel.frame.size
        let screen = parent.screen?.visibleFrame ?? .zero
        var x = parent.frame.maxX + 4
        if x + size.width > screen.maxX { x = parent.frame.minX - size.width - 4 }
        let y = max(screen.minY, parent.frame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
