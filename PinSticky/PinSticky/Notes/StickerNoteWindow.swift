import AppKit
import ObjectiveC

final class StickerNoteWindow: NSPanel {
    var noteMouseDownHandler: ((Bool) -> Void)?
    var noteMouseUpHandler: (() -> Void)?
    var noteMouseDraggedHandler: ((CGPoint) -> Void)?
    /// Called with (sizeDelta, originDelta) whenever the window's own
    /// resize (from any edge/corner) actually changes its size. Both
    /// deltas matter, not just the resulting size: resizing from the left
    /// edge grows the window while also shifting its origin left, and a
    /// selected sibling needs to replicate *that same shift*, not just end
    /// up at the same size - otherwise it grows from the opposite edge,
    /// mirrored.
    var noteWindowResizedHandler: ((CGSize, CGPoint) -> Void)?
    var noteShortcutHandler: ((PinStickyShortcutKey) -> Bool)?
    var collapsedClickHandler: (() -> Void)?
    var collapsedDragEndedHandler: (() -> Void)?
    var pinchHandler: ((CGFloat) -> Void)?
    var hoverHandler: (() -> Void)?
    var stackSwipeHandler: ((Int) -> Void)?

    var isProgrammaticallyMoving = false

    // `.nonactivatingPanel` lets the panel receive events (clicks, and
    // crucially passive trackpad scroll/swipe) while PinSticky isn't the
    // frontmost app - without it, macOS only delivers a mouseDown (which
    // activates the app as a side effect) to a background app's window, and
    // hover-only gestures like a two-finger swipe never arrive at all. The
    // collapsed dot already relied on this; the expanded note needs it too.
    private static let expandedStyleMask: NSWindow.StyleMask = [.borderless, .resizable, .nonactivatingPanel]
    private var handlesCollapsedDotInteraction = false
    private var suppressesBackgroundMoveForResize = false
    private var accumulatedMagnification: CGFloat = 0
    private var accumulatedSwipeX: CGFloat = 0
    private var accumulatedSwipeY: CGFloat = 0

    /// `NSAnimationContext`/`animator()` calls dispatch through a dynamically
    /// created Objective-C proxy subclass whose Swift stored properties are
    /// not valid to read (it is a distinct allocation from the real window).
    /// Swift's `type(of:)` can report the *declared* class instead of the
    /// proxy's swizzled `isa` on some OS versions, so we query the
    /// Objective-C runtime directly, which always reflects the true class.
    private var isAnimationProxy: Bool {
        guard let runtimeClass = object_getClass(self) else { return false }
        return NSStringFromClass(runtimeClass).contains("Animator")
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !isAnimationProxy else {
            super.setFrame(frameRect, display: flag)
            return
        }

        let originDelta = CGPoint(x: frameRect.origin.x - frame.origin.x, y: frameRect.origin.y - frame.origin.y)
        let sizeDelta = CGSize(width: frameRect.width - frame.width, height: frameRect.height - frame.height)
        super.setFrame(frameRect, display: flag)
        if !isProgrammaticallyMoving {
            if originDelta.x != 0 || originDelta.y != 0 {
                noteMouseDraggedHandler?(originDelta)
            }
            if sizeDelta.width != 0 || sizeDelta.height != 0 {
                noteWindowResizedHandler?(sizeDelta, originDelta)
            }
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        guard !isAnimationProxy else {
            super.setFrameOrigin(newOrigin)
            return
        }

        let originDelta = CGPoint(x: newOrigin.x - frame.origin.x, y: newOrigin.y - frame.origin.y)
        super.setFrameOrigin(newOrigin)
        if !isProgrammaticallyMoving && (originDelta.x != 0 || originDelta.y != 0) {
            noteMouseDraggedHandler?(originDelta)
        }
    }

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
        acceptsMouseMovedEvents = true
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
            let isCommandPressed = event.modifierFlags.contains(.command)
            noteMouseDownHandler?(isCommandPressed)
        }

        if event.type == .scrollWheel {
            trackStackSwipe(event)
        }

        super.sendEvent(event)

        if event.type == .leftMouseUp {
            if suppressesBackgroundMoveForResize {
                suppressesBackgroundMoveForResize = false
                isMovableByWindowBackground = true
            }
            noteMouseUpHandler?()
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

    /// Trackpad pinch (`magnify`) events, like scroll/swipe, are not
    /// reliably forwarded up the responder chain to the window from every
    /// subview - the note's `NSScrollView`-backed text editor in particular
    /// can swallow them. `NoteEditorScrollView` also calls this directly
    /// from its own `magnify(with:)` override so pinch-to-collapse/expand
    /// works no matter where over the note the gesture starts. Returns
    /// whether the pinch just triggered a collapse/expand, so callers can
    /// decide whether to still let the event fall through to `super`.
    @discardableResult
    func trackPinchMagnification(_ event: NSEvent) -> Bool {
        // Both the window's own `magnify(with:)` and `NoteEditorScrollView`
        // can end up seeing the same physical pinch tick, so
        // `accumulatedMagnification` may get double-counted per tick. That's
        // relatively harmless on its own (it just reaches the toggle
        // threshold with a bit less physical pinching); the reversing
        // mid-gesture double-toggle it could cause is now guarded against
        // where it actually matters, in `NoteWindowController.handlePinch`
        // (skips any pinch tick while a collapse/expand transition is
        // already animating).
        //
        // A previous version of this method also de-duplicated by
        // `event.timestamp`, on the theory that both call sites see the
        // literal same `NSEvent`. That backfired: magnify events apparently
        // don't get a fresh timestamp per tick the way scroll events do, so
        // every tick after the first in a gesture matched the "last seen"
        // timestamp and was dropped - `accumulatedMagnification` could never
        // climb past the very first, tiny tick, so pinch stopped
        // registering at all.
        //
        // Only activate/reorder the window once, on the gesture's first
        // tick - not on every single one. Calling `makeKeyAndOrderFront`
        // repeatedly mid-gesture reorders the window server's view of
        // things while the trackpad driver is still tracking which window
        // the gesture belongs to, which looked like the likely cause of
        // pinch intermittently dropping out mid-gesture or failing to
        // register at all while hovering an inactive note.
        if event.phase == .began || event.phase.isEmpty {
            noteMouseDownHandler?(false)
        }
        accumulatedMagnification += event.magnification

        if event.phase == .ended || event.phase == .cancelled {
            accumulatedMagnification = 0
            return false
        }

        let threshold: CGFloat = 0.22
        guard abs(accumulatedMagnification) >= threshold else { return false }

        pinchHandler?(accumulatedMagnification)
        accumulatedMagnification = 0
        return true
    }

    override func magnify(with event: NSEvent) {
        if !trackPinchMagnification(event) {
            super.magnify(with: event)
        }
    }

    func prepareForHoverGesture() {
        hoverHandler?()
    }

    /// Trackpad two-finger swipe events are ordinary `.scrollWheel` events.
    /// We observe them in `sendEvent` so every part of the window sees them
    /// even if no subview would otherwise forward the event up the
    /// responder chain. Not private: `NoteEditorScrollView` (used by the
    /// note's text editor, which covers most of the note's area) also calls
    /// this directly from its own `scrollWheel(with:)`, since in practice
    /// scroll events over that view were not reliably reaching this handler
    /// through the normal dispatch path.
    func trackStackSwipe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, stackSwipeHandler != nil else { return }

        switch event.phase {
        case .began:
            accumulatedSwipeX = 0
            accumulatedSwipeY = 0
        case .changed:
            accumulatedSwipeX += event.scrollingDeltaX
            accumulatedSwipeY += event.scrollingDeltaY
        case .ended, .cancelled:
            let threshold: CGFloat = 80
            if abs(accumulatedSwipeX) > abs(accumulatedSwipeY), abs(accumulatedSwipeX) >= threshold {
                stackSwipeHandler?(accumulatedSwipeX < 0 ? 1 : -1)
            }
            accumulatedSwipeX = 0
            accumulatedSwipeY = 0
        default:
            break
        }
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
            noteMouseDownHandler?(false)
            return false
        }

        return false
    }

    private func trackCollapsedDotMouseSession() {
        noteMouseDownHandler?(false)

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
