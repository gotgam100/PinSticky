import AppKit

final class StickerNoteWindow: NSPanel {
    var noteMouseDownHandler: (() -> Void)?

    private static let expandedStyleMask: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView]

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: Self.expandedStyleMask,
            backing: .buffered,
            defer: false
        )

        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView?.wantsLayer = true
        contentView?.layer?.borderWidth = 0

        configureExpandedChrome()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            noteMouseDownHandler?()
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeStandardTextShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func applyExpandedStyle() {
        styleMask = Self.expandedStyleMask
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        configureExpandedChrome()
    }

    func applyCollapsedStyle() {
        styleMask = [.borderless, .nonactivatingPanel]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        minSize = NSSize(width: 28, height: 28)
        hideStandardWindowButtons()
    }

    private func configureExpandedChrome() {
        title = ""
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        minSize = NSSize(
            width: NoteView.resizableFloorSize,
            height: NoteView.resizableFloorSize + NoteView.toolbarHeight
        )
        if #available(macOS 11.0, *) {
            titlebarSeparatorStyle = .none
        }
        hideStandardWindowButtons()
    }

    private func hideStandardWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func routeStandardTextShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let textView = firstResponder as? NSTextView else {
            return false
        }

        switch event.pinStickyShortcutKey {
        case .undo:
            textView.undoManager?.undo()
        case .redo:
            textView.undoManager?.redo()
        case .copy:
            textView.copy(nil)
        case .paste:
            textView.paste(nil)
        case .cut:
            textView.cut(nil)
        case .selectAll:
            textView.selectAll(nil)
        default:
            return false
        }
        return true
    }
}
