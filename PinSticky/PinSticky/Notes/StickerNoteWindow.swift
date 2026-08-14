import AppKit

final class StickerNoteWindow: NSPanel {
    var noteMouseDownHandler: (() -> Void)?
    var noteShortcutHandler: ((PinStickyShortcutKey) -> Bool)?
    var collapsedClickHandler: (() -> Void)?
    var collapsedDragEndedHandler: (() -> Void)?
    var pinchHandler: ((CGFloat) -> Void)?

    private static let expandedStyleMask: NSWindow.StyleMask = [.borderless, .resizable]
    private var handlesCollapsedDotInteraction = false
    private var suppressesBackgroundMoveForResize = false
    private var accumulatedMagnification: CGFloat = 0

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
        applyCollectionBehavior()
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
        if handlesCollapsedDotInteraction, handleCollapsedDotEvent(event) {
            return
        }

        if event.type == .leftMouseDown, !storeIsCollapsedStyle {
            suppressesBackgroundMoveForResize = resizeAreaContains(event.locationInWindow)
            isMovableByWindowBackground = !suppressesBackgroundMoveForResize
        }

        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            noteMouseDownHandler?()
        }
        super.sendEvent(event)

        if event.type == .leftMouseUp, suppressesBackgroundMoveForResize {
            suppressesBackgroundMoveForResize = false
            isMovableByWindowBackground = true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeStandardTextShortcut(event) {
            return true
        }
        if let shortcutAction = AppShortcutAction.matching(event),
           let shortcut = shortcutAction.pinStickyShortcutKey,
           noteShortcutHandler?(shortcut) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func magnify(with event: NSEvent) {
        noteMouseDownHandler?()
        accumulatedMagnification += event.magnification

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedMagnification = 0
            super.magnify(with: event)
            return
        }

        let threshold: CGFloat = 0.22
        guard abs(accumulatedMagnification) >= threshold else {
            super.magnify(with: event)
            return
        }

        pinchHandler?(accumulatedMagnification)
        accumulatedMagnification = 0
    }

    func applyExpandedStyle() {
        handlesCollapsedDotInteraction = false
        suppressesBackgroundMoveForResize = false
        styleMask = Self.expandedStyleMask
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        configureExpandedChrome()
    }

    func applyCollapsedStyle() {
        handlesCollapsedDotInteraction = true
        suppressesBackgroundMoveForResize = false
        styleMask = [.borderless, .nonactivatingPanel]
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        minSize = NSSize(width: NoteView.collapsedDotHitSize, height: NoteView.collapsedDotHitSize)
        hideStandardWindowButtons()
    }

    func applyLevel(for displayMode: NoteDisplayMode) {
        level = displayMode == .unpinned ? .normal : .floating
        applyCollectionBehavior()
    }

    private func applyCollectionBehavior() {
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
    }

    private func configureExpandedChrome() {
        title = ""
        minSize = NSSize(
            width: NoteView.resizableFloorSize,
            height: NoteView.resizableFloorSize
        )
        hideStandardWindowButtons()
    }

    private var storeIsCollapsedStyle: Bool {
        styleMask.contains(.nonactivatingPanel)
    }

    private func resizeAreaContains(_ point: NSPoint) -> Bool {
        let edgeThickness: CGFloat = 18
        let cornerSize: CGFloat = 30
        let width = frame.width
        let height = frame.height
        guard width > edgeThickness, height > edgeThickness else { return false }

        let sideMaxY = max(cornerSize, height - NoteView.toolbarHeight)
        let isInVerticalResizeBand = point.y >= cornerSize && point.y <= sideMaxY
        let isInLeftSide = point.x <= edgeThickness && isInVerticalResizeBand
        let isInRightSide = point.x >= width - edgeThickness && isInVerticalResizeBand
        let isInBottom = point.y <= edgeThickness && point.x >= cornerSize && point.x <= width - cornerSize
        let isInBottomLeftCorner = point.x <= cornerSize && point.y <= cornerSize
        let isInBottomRightCorner = point.x >= width - cornerSize && point.y <= cornerSize

        return isInLeftSide || isInRightSide || isInBottom || isInBottomLeftCorner || isInBottomRightCorner
    }

    private func hideStandardWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func handleCollapsedDotEvent(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown {
            trackCollapsedDotMouseSession()
            return true
        }

        if event.type == .leftMouseDragged || event.type == .leftMouseUp {
            return true
        }

        if event.type == .rightMouseDown {
            noteMouseDownHandler?()
            return false
        }

        return false
    }

    private func trackCollapsedDotMouseSession() {
        noteMouseDownHandler?()

        let dragThreshold: CGFloat = 16
        let startOrigin = frame.origin
        let startScreenPoint = NSEvent.mouseLocation
        var didDrag = false

        while true {
            guard let nextEvent = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                break
            }

            let current = NSEvent.mouseLocation
            let delta = CGPoint(
                x: current.x - startScreenPoint.x,
                y: current.y - startScreenPoint.y
            )

            switch nextEvent.type {
            case .leftMouseDragged:
                guard didDrag || hypot(delta.x, delta.y) > dragThreshold else {
                    continue
                }
                didDrag = true
                setFrameOrigin(CGPoint(
                    x: startOrigin.x + delta.x,
                    y: startOrigin.y + delta.y
                ))
            case .leftMouseUp:
                if didDrag {
                    collapsedDragEndedHandler?()
                } else {
                    collapsedClickHandler?()
                }
                return
            default:
                break
            }
        }
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
