import AppKit
import PufferCore

/// The list of matching emoji shown next to the text cursor. It never takes
/// focus: the app being typed in keeps its caret, and the keys that drive
/// the list are intercepted by the event tap. Main thread only.
@MainActor
final class EmojiPopup {
    /// The panel's frame in top-left coordinates while it is on screen, nil
    /// once it is hidden. The engine takes the popup's keys only meanwhile.
    var onFrameChange: ((CGRect?) -> Void)?

    private let panel: Panel
    private let list: ListView
    /// Where the popup sits for the current session, once placed. It stays
    /// put while the user types rather than chasing the caret.
    private var placement: Placement?
    /// Incremented by every hide, so a slow placement for a finished session
    /// is dropped.
    private var generation = 0
    private var placing = false

    private struct Placement {
        var x: CGFloat
        /// Below the caret, the top edge stays fixed as rows come and go;
        /// above it, the bottom edge does.
        var anchorY: CGFloat
        var below: Bool
    }

    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 5

    init(onChoose: @escaping (Int) -> Void) {
        list = ListView(onChoose: onChoose)
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        list.frame = background.bounds
        list.autoresizingMask = [.width, .height]
        background.addSubview(list)
        panel.contentView = background
    }

    func handle(_ command: EmojiPopupCommand) {
        switch command {
        case .show(let matches, let selected):
            show(matches: matches, selected: selected)
        case .hide:
            hide()
        }
    }

    func show(matches: [Emoji], selected: Int) {
        list.matches = matches
        list.selected = selected
        list.needsDisplay = true

        if placement != nil {
            layOut()
            return
        }
        guard !placing else { return }
        placing = true
        // Give the app a moment to draw the character just typed, so the
        // caret it reports is after it.
        placeWhenReady(generation: generation, attempt: 0, after: 0.03)
    }

    /// Looks up the caret and shows the panel there. An app sometimes can't
    /// say where its caret is for a moment, so try a couple more times before
    /// settling for the mouse pointer.
    private func placeWhenReady(generation: Int, attempt: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.generation else { return }
            guard !list.matches.isEmpty else {
                placing = false
                return
            }
            let caret = CaretLocator.caretRect()
            if caret == nil, attempt < 2 {
                placeWhenReady(generation: generation, attempt: attempt + 1, after: 0.05)
                return
            }
            placing = false
            placement = place(at: caret)
            layOut()
            panel.orderFrontRegardless()
            onFrameChange?(CaretLocator.toTopLeft(panel.frame))
        }
    }

    func hide() {
        generation += 1
        placement = nil
        placing = false
        list.matches = []
        if panel.isVisible { panel.orderOut(nil) }
        onFrameChange?(nil)
    }

    private var height: CGFloat {
        CGFloat(list.matches.count) * Self.rowHeight + Self.padding * 2
    }

    /// Below the caret if there is room, otherwise above it, on its screen.
    private func place(at caret: NSRect?) -> Placement {
        let mouse = NSEvent.mouseLocation
        let anchor = caret ?? NSRect(x: mouse.x, y: mouse.y - 4, width: 0, height: 20)
        let point = NSPoint(x: anchor.minX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let tallest = CGFloat(EmojiCatalog.maxResults) * Self.rowHeight + Self.padding * 2

        let x = min(max(anchor.minX - 12, visible.minX + 4), visible.maxX - Self.width - 4)
        if anchor.minY - 4 - tallest >= visible.minY || caret == nil {
            return Placement(x: x, anchorY: anchor.minY - 4, below: true)
        }
        return Placement(x: x, anchorY: anchor.maxY + 4, below: false)
    }

    private func layOut() {
        guard let placement else { return }
        let y = placement.below ? placement.anchorY - height : placement.anchorY
        panel.setFrame(NSRect(x: placement.x, y: y, width: Self.width, height: height), display: true)
        if panel.isVisible { onFrameChange?(CaretLocator.toTopLeft(panel.frame)) }
    }

    /// Never becomes key, so the app being typed in keeps its caret.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class ListView: NSView {
        var matches: [Emoji] = []
        var selected = 0
        private let onChoose: (Int) -> Void

        init(onChoose: @escaping (Int) -> Void) {
            self.onChoose = onChoose
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            for (index, emoji) in matches.enumerated() {
                let row = rowRect(index)
                let isSelected = index == selected
                if isSelected {
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSBezierPath(roundedRect: row.insetBy(dx: EmojiPopup.padding, dy: 0), xRadius: 5, yRadius: 5).fill()
                }
                let symbol = NSAttributedString(string: emoji.character, attributes: [
                    .font: NSFont.systemFont(ofSize: 17),
                ])
                symbol.draw(at: NSPoint(x: row.minX + 12, y: row.minY + 4))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let name = NSAttributedString(string: emoji.name, attributes: [
                    .font: NSFont.menuFont(ofSize: 13),
                    .foregroundColor: isSelected ? NSColor.white : NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ])
                name.draw(in: NSRect(x: row.minX + 42, y: row.minY + 6, width: row.width - 54, height: 18))
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let index = Int((point.y - EmojiPopup.padding) / EmojiPopup.rowHeight)
            if matches.indices.contains(index), point.y >= EmojiPopup.padding {
                onChoose(index)
            }
        }

        private func rowRect(_ index: Int) -> NSRect {
            NSRect(x: 0, y: EmojiPopup.padding + CGFloat(index) * EmojiPopup.rowHeight,
                   width: bounds.width, height: EmojiPopup.rowHeight)
        }
    }
}
