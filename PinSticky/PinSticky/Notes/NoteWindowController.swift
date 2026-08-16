import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    private static let toolbarHeight: CGFloat = NoteView.toolbarHeight

    let store: NoteStore
    private let newNote: (CGRect) -> Void
    private let deleteNote: (UUID) -> Void
    private let activateNote: (UUID) -> Void
    private let noteFrameChanged: () -> Void
    private let selectionState: NoteSelectionState
    private let attachNotes: (NoteStore, RunningApplicationInfo?) -> Void
    private let unpinNotes: (NoteStore) -> Void
    private let updateThemeForSelection: (NoteStore, String) -> Void
    private let updateFontSizeForSelection: (NoteStore, Double) -> Void
    private let collapseSelection: (NoteStore) -> Void
    private let stackNote: (UUID, UUID) -> Void
    private let unstackNote: (UUID) -> Void
    private let navigateStack: (UUID, Int) -> Void
    private let visibilityContext: () -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>)
    private let resizeSelectedNotes: ((CGSize, CGPoint, UUID) -> Void)?
    var isWindowVisible: Bool { window.isVisible }
    private let window: StickerNoteWindow
    private let placementManager = WindowPlacementManager()
    private var noteObserver: AnyCancellable?
    private var isApplyingTransition = false
    private var isRefreshingVisibility = false
    private var isManuallyHidden = false
    private var isVisible = false
    private var presentationSnapshot: PresentationSnapshot
    private let overlapState = NoteOverlapState()
    private var collapsedWindowInset: CGFloat {
        (NoteView.collapsedDotHitSize - NoteView.collapsedDotSize) / 2
    }

    init(
        store: NoteStore,
        newNote: @escaping (CGRect) -> Void,
        deleteNote: @escaping (UUID) -> Void,
        activateNote: @escaping (UUID) -> Void,
        noteFrameChanged: @escaping () -> Void,
        selectionState: NoteSelectionState,
        attachNotes: @escaping (NoteStore, RunningApplicationInfo?) -> Void,
        unpinNotes: @escaping (NoteStore) -> Void,
        updateThemeForSelection: @escaping (NoteStore, String) -> Void,
        updateFontSizeForSelection: @escaping (NoteStore, Double) -> Void,
        collapseSelection: @escaping (NoteStore) -> Void,
        stackNote: @escaping (UUID, UUID) -> Void,
        unstackNote: @escaping (UUID) -> Void,
        navigateStack: @escaping (UUID, Int) -> Void,
        visibilityContext: @escaping () -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>),
        resizeSelectedNotes: @escaping (CGSize, CGPoint, UUID) -> Void
    ) {
        self.store = store
        self.newNote = newNote
        self.deleteNote = deleteNote
        self.activateNote = activateNote
        self.noteFrameChanged = noteFrameChanged
        self.selectionState = selectionState
        self.attachNotes = attachNotes
        self.unpinNotes = unpinNotes
        self.updateThemeForSelection = updateThemeForSelection
        self.updateFontSizeForSelection = updateFontSizeForSelection
        self.collapseSelection = collapseSelection
        self.stackNote = stackNote
        self.unstackNote = unstackNote
        self.navigateStack = navigateStack
        self.visibilityContext = visibilityContext
        self.resizeSelectedNotes = resizeSelectedNotes
        let initialFrame = Self.windowFrame(forNoteFrame: placementManager.clampedFrame(store.note.expandedFrame.cgRect))
        window = StickerNoteWindow(frame: initialFrame)
        presentationSnapshot = PresentationSnapshot(note: store.note)
        super.init()
        window.delegate = self
        window.noteMouseDownHandler = { [weak self] isCommandPressed in
            guard let self else { return }
            if isCommandPressed {
                self.toggleSelected()
            }
            self.selectAndBringToFront()
            self.window.makeKeyAndOrderFront(nil)
        }
        window.noteWindowResizedHandler = { [weak self] sizeDelta, originDelta in
            guard let self else { return }
            if self.selectionState.isSelected(self.store.note.id) {
                self.resizeSelectedNotes?(sizeDelta, originDelta, self.store.note.id)
            }
        }
        window.collapsedClickHandler = { [weak self] in
            self?.toggleCollapsed()
        }
        window.collapsedDragEndedHandler = { [weak self] in
            self?.captureCurrentFrame()
            self?.noteFrameChanged()
        }
        window.pinchHandler = { [weak self] magnification in
            self?.handlePinch(magnification: magnification)
        }
        window.hoverHandler = { [weak self] in
            guard let self else { return }
            self.window.orderFrontRegardless()
        }
        window.stackSwipeHandler = { [weak self] direction in
            self?.handleStackSwipe(direction: direction)
        }
        window.noteShortcutHandler = { [weak self] shortcut in
            guard let self else { return false }
            switch shortcut {
            case .selectNote:
                self.toggleSelected()
                return true
            case .closeNote:
                self.deleteNote(self.store.note.id)
                return true
            default:
                return false
            }
        }
        noteObserver = store.$note.sink { [weak self] note in
            guard let self, !self.isApplyingTransition else { return }
            self.applyPresentationChangeIfNeeded(note)
        }
        applyContent()
    }

    func show(
        forceVisible: Bool = false,
        resetManualHidden: Bool = true,
        animateAppearance: Bool = false
    ) {
        if resetManualHidden {
            isManuallyHidden = false
        }
        applyContent()
        if forceVisible {
            if !isManuallyHidden {
                showWindow(animated: animateAppearance, bounces: animateAppearance)
            }
        } else {
            refreshVisibilityWithCurrentContext()
        }
    }

    func revealIfHiddenByAttachment() {
        guard !isManuallyHidden else { return }
        applyContent()
        showWindow(animated: false)
    }

    func toggleCollapsed() {
        let nextCollapsedState = !store.note.isCollapsed
        if nextCollapsedState {
            captureExpandedFrameIfNeeded()
        } else {
            moveExpandedFrameToCollapsedOrigin()
        }

        isApplyingTransition = true
        store.updateCollapsed(nextCollapsedState)
        applyContent(animated: true)
        finishTransitionAfterAnimation()
    }

    var windowNumber: Int {
        window.windowNumber
    }

    func containsScreenPoint(_ screenPoint: CGPoint) -> Bool {
        window.isVisible && window.frame.contains(screenPoint)
    }

    func handleHoverMagnify(_ event: NSEvent) {
        _ = window.trackPinchMagnification(event)
    }

    func collapseIfExpanded() {
        guard !store.note.isCollapsed else { return }
        toggleCollapsed()
    }

    private func handlePinch(magnification: CGFloat) {
        // Not gated on isKeyWindow/isMainWindow, same reasoning as the stack
        // swipe: pinch-to-collapse/expand should work while just hovering.
        //
        // Also ignore pinch ticks while a collapse/expand transition is
        // already running: the same physical pinch tick can reach this
        // handler more than once (the window's own `magnify` override and
        // the text editor's scroll view both observe magnify events, and
        // one can bubble into the other). Without this guard, a duplicated
        // tick could call `toggleCollapsed()` again mid-animation, flipping
        // straight back to the state it just left - which canceled out
        // visually and looked like pinch "did nothing".
        guard !isApplyingTransition else { return }
        if magnification < 0, !store.note.isCollapsed {
            toggleCollapsed()
        } else if magnification > 0, store.note.isCollapsed {
            toggleCollapsed()
        }
    }

    private func handleStackSwipe(direction: Int) {
        // Intentionally not gated on isKeyWindow/isMainWindow: trackpad
        // swipes should page a stack just by hovering over it, the same way
        // scrolling an inactive window works elsewhere on macOS.
        guard store.stackIndex != nil else { return }
        navigateStack(store.note.stackParentID ?? store.note.id, direction)
    }

    func captureCurrentFrame() {
        updateStoredFrameWithoutRefreshingContent {
            captureCurrentFrameWithoutRefreshGuard()
        }
    }

    private func captureCurrentFrameWithoutRefreshGuard() {
        if store.note.isCollapsed {
            store.updateCollapsedOrigin(dotOrigin(forCollapsedWindowFrame: window.frame))
        } else {
            store.updateExpandedFrame(Self.noteFrame(forWindowFrame: window.frame))
        }
    }

    func refreshVisibility(
        frontmostBundleIdentifier: String? = nil,
        visibleBundleIdentifiers: Set<String> = []
    ) {
        guard !isRefreshingVisibility else { return }
        guard !isManuallyHidden else {
            if window.isVisible {
                hideWindow(animated: false)
            }
            return
        }
        isRefreshingVisibility = true
        defer { isRefreshingVisibility = false }

        switch store.note.displayMode {
        case .always:
            showWindow(animated: true)
        case .unpinned:
            showWindow(animated: true)
        case .whenAppIsActive:
            if let bundleIdentifier = store.note.attachedBundleIdentifier,
               frontmostBundleIdentifier == bundleIdentifier,
               visibleBundleIdentifiers.contains(bundleIdentifier) {
                showWindow(animated: true)
            } else {
                captureCurrentFrame()
                hideWindow(animated: true)
            }
        }
    }

    private func refreshVisibilityWithCurrentContext() {
        let context = visibilityContext()
        refreshVisibility(
            frontmostBundleIdentifier: context.frontmostBundleIdentifier,
            visibleBundleIdentifiers: context.visibleBundleIdentifiers
        )
    }

    /// Applies the same size *and* origin change a selected sibling just
    /// underwent, instead of forcing this window to some absolute size
    /// while keeping its own origin fixed - the latter ignores which edge
    /// the sibling was actually resized from, so a resize starting at, say,
    /// the left edge (grows the window while shifting its origin left)
    /// would apply here as pure growth with the origin pinned, which grows
    /// from the *right* edge instead: a mirror image of the real resize.
    func resizeBy(sizeDelta: CGSize, originDelta: CGPoint) {
        window.isProgrammaticallyMoving = true
        let currentFrame = window.frame
        let newFrame = CGRect(
            x: currentFrame.origin.x + originDelta.x,
            y: currentFrame.origin.y + originDelta.y,
            width: currentFrame.width + sizeDelta.width,
            height: currentFrame.height + sizeDelta.height
        )
        window.setFrame(newFrame, display: true)

        // Update model immediately
        let noteFrame = Self.noteFrame(forWindowFrame: newFrame)
        updateStoredFrameWithoutRefreshingContent {
            store.updateExpandedFrame(noteFrame)
        }
        
        captureCurrentFrame()
        noteFrameChanged()
        window.isProgrammaticallyMoving = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !window.isProgrammaticallyMoving else { return }
        guard !collapseIfNeededFromCurrentWindowFrame() else { return }

        captureCurrentFrame()
        noteFrameChanged()
    }

    func windowDidResize(_ notification: Notification) {
        guard !window.isProgrammaticallyMoving else { return }
        guard !store.note.isCollapsed, !isApplyingTransition else { return }
        guard !collapseIfNeededFromCurrentWindowFrame() else { return }
        let noteFrame = Self.noteFrame(forWindowFrame: window.frame)
        updateStoredFrameWithoutRefreshingContent {
            store.updateExpandedFrame(noteFrame)
        }
        noteFrameChanged()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        selectAndBringToFront()
    }

    func bringToFront() {
        guard window.isVisible else { return }
        orderWindowFront()
    }

    func bringToFrontForActiveSelection() {
        guard window.isVisible else { return }
        if store.note.displayMode == .unpinned {
            window.level = .floating
        }
        window.orderFrontRegardless()
    }

    func bringToFrontForTemporaryReveal() {
        guard window.isVisible else { return }
        window.orderFrontRegardless()
    }

    func restoreDefaultWindowLevel() {
        window.applyLevel(for: store.note.displayMode)
    }

    func setHasOverlap(_ hasOverlap: Bool) {
        overlapState.hasOverlap = hasOverlap
    }

    var visibleFrame: CGRect? {
        guard window.isVisible else { return nil }
        return window.frame
    }

    var isUserHidden: Bool {
        isManuallyHidden
    }

    func toggleSelected() {
        selectionState.toggle(store.note.id)
    }

    private func selectAndBringToFront() {
        activateNote(store.note.id)
    }

    private func applyContent(animated: Bool = false) {
        presentationSnapshot = PresentationSnapshot(note: store.note)

        if store.note.isCollapsed {
            let dotOrigin = placementManager.clampedDotOrigin(store.note.collapsedOrigin.cgPoint)
            let dotFrame = collapsedWindowFrame(forDotOrigin: dotOrigin)
            window.applyLevel(for: store.note.displayMode)
            let applyDotContent: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.window.applyCollapsedStyle()
                self.window.contentView = ClearHostingView(rootView: DotView(
                    store: self.store,
                    overlapState: self.overlapState,
                    expand: { [weak self] in
                        self?.toggleCollapsed()
                    },
                    dragEnded: { [weak self] in
                        self?.captureCurrentFrame()
                        self?.noteFrameChanged()
                    }
                ))
            }
            if animated {
                animateCollapseIntoDot(dotFrame: dotFrame, completion: applyDotContent)
            } else {
                window.isProgrammaticallyMoving = true
                window.setFrame(dotFrame, display: true)
                window.isProgrammaticallyMoving = false
                applyDotContent()
            }
        } else {
            let frame = placementManager.clampedFrame(store.note.expandedFrame.cgRect)
            window.applyExpandedStyle()
            window.applyLevel(for: store.note.displayMode)
            setFrame(Self.windowFrame(forNoteFrame: frame), animated: animated)
            window.contentView = ClearHostingView(rootView: NoteView(
                store: store,
                overlapState: overlapState,
                selectionState: selectionState,
                newNote: { [weak self] in
                    guard let self else { return }
                    self.captureCurrentFrame()
                    self.newNote(Self.noteFrame(forWindowFrame: self.window.frame))
                },
                deleteNote: { [deleteNote, store] in deleteNote(store.note.id) }
            ) { [weak self] in
                self?.toggleCollapsed()
            } attachmentDragSucceeded: { [weak self] in
                self?.shakeForAttachment()
            } attachNotes: { [attachNotes, store] application in
                attachNotes(store, application)
            } unpinNotes: { [unpinNotes, store] in
                unpinNotes(store)
            } updateThemeForSelection: { [updateThemeForSelection, store] themeID in
                updateThemeForSelection(store, themeID)
            } updateFontSizeForSelection: { [updateFontSizeForSelection, store] delta in
                updateFontSizeForSelection(store, delta)
            } collapseSelection: { [collapseSelection, store] in
                collapseSelection(store)
            } stackNote: { [stackNote] targetID, refID in
                stackNote(targetID, refID)
            } unstackNote: { [unstackNote] noteID in
                unstackNote(noteID)
            } navigateStack: { [navigateStack] parentID, delta in
                navigateStack(parentID, delta)
            })
        }
    }

    private func shakeForAttachment() {
        let originalFrame = window.frame
        let offsets: [CGFloat] = [0, -4, 1, -1, 0]

        window.isProgrammaticallyMoving = true
        for (index, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) { [weak self] in
                guard let self else { return }
                self.window.setFrame(originalFrame.offsetBy(dx: 0, dy: offset), display: true)
                if index == offsets.count - 1 {
                    self.captureCurrentFrame()
                    self.window.isProgrammaticallyMoving = false
                }
            }
        }
    }

    /// Collapse without animating the window frame. AppKit frame
    /// interpolation can nudge a borderless panel a few pixels sideways
    /// before it lands on the final dot frame, so the window jumps to the dot
    /// while fully transparent and only the dot view itself animates in.
    private func animateCollapseIntoDot(dotFrame: CGRect, completion: @escaping @MainActor @Sendable () -> Void) {
        window.isProgrammaticallyMoving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.07
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.window.alphaValue = 0
                self.window.setFrame(dotFrame, display: true)
                completion()
                self.window.displayIfNeeded()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.window.animator().alphaValue = 1
                } completionHandler: {
                    Task { @MainActor in
                        self.window.alphaValue = 1
                        self.window.isProgrammaticallyMoving = false
                    }
                }
            }
        }
    }

    private func setFrame(_ frame: CGRect, animated: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard animated else {
            window.isProgrammaticallyMoving = true
            window.setFrame(frame, display: true)
            window.isProgrammaticallyMoving = false
            completion?()
            return
        }

        // Overshoot the final size slightly, then settle back down. (An
        // 8%/26pt version of this read as too large a pop for a full-size
        // note - this splits the difference between that and the original,
        // barely-visible 3.5%/10pt.)
        let overshoot = frame.insetBy(dx: -min(frame.width * 0.05, 16), dy: -min(frame.height * 0.05, 16))
        window.isProgrammaticallyMoving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(overshoot, display: true)
        } completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().setFrame(frame, display: true)
                } completionHandler: {
                    Task { @MainActor in
                        self.window.isProgrammaticallyMoving = false
                        completion?()
                    }
                }
            }
        }
    }

    private func captureExpandedFrameIfNeeded() {
        guard !store.note.isCollapsed else { return }
        let noteFrame = Self.noteFrame(forWindowFrame: window.frame)
        updateStoredFrameWithoutRefreshingContent {
            store.updateExpandedFrame(noteFrame)
            store.updateCollapsedOrigin(CGPoint(
                x: noteFrame.midX - NoteView.collapsedDotSize / 2,
                y: noteFrame.midY - NoteView.collapsedDotSize / 2
            ))
        }
    }

    private func collapseFromResizeToDefaultSize() {
        let collapsedOrigin = placementManager.clampedDotOrigin(
            CGPoint(
                x: window.frame.midX - NoteView.collapsedDotSize / 2,
                y: window.frame.midY - NoteView.collapsedDotSize / 2
            )
        )
        let restoreFrame = defaultSizedFrame(centeredOn: collapsedOrigin)

        isApplyingTransition = true
        store.updateExpandedFrame(restoreFrame)
        store.updateCollapsedOrigin(collapsedOrigin)
        store.updateCollapsed(true)
        applyContent(animated: true)
        finishTransitionAfterAnimation()
    }

    private func collapseIfNeededFromCurrentWindowFrame() -> Bool {
        guard !store.note.isCollapsed, !isApplyingTransition else { return false }
        let noteFrame = Self.noteFrame(forWindowFrame: window.frame)
        guard shouldCollapseFromResize(noteFrame) else { return false }
        collapseFromResizeToDefaultSize()
        return true
    }

    private func defaultSizedFrame(centeredOn dotOrigin: CGPoint) -> CGRect {
        let size = CGSize(width: 320, height: 260)
        let frame = CGRect(
            x: dotOrigin.x + NoteView.collapsedDotSize / 2 - size.width / 2,
            y: dotOrigin.y + NoteView.collapsedDotSize / 2 - size.height / 2,
            width: size.width,
            height: size.height
        )
        return placementManager.clampedFrame(frame)
    }

    private func shouldCollapseFromResize(_ noteFrame: CGRect) -> Bool {
        let reachedToolbarWidthLimit = noteFrame.width <= NoteView.toolbarCompressedWidth
        let reachedVerticalLimit = noteFrame.height <= NoteView.collapseAxisThreshold
        let reachedResizeFloor = noteFrame.height <= NoteView.resizableFloorSize + 1
            || noteFrame.width <= NoteView.resizableFloorSize + 1
        return reachedToolbarWidthLimit
            || reachedVerticalLimit
            || reachedResizeFloor
    }

    private func showWindow(animated: Bool, bounces: Bool = false) {
        guard !isVisible || !window.isVisible else {
            return
        }

        isVisible = true
        guard animated else {
            window.alphaValue = 1
            orderWindowFront()
            return
        }

        if bounces {
            animateWindowAppearance()
            return
        }

        window.alphaValue = 0
        orderWindowFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func hideWindow(animated: Bool) {
        guard isVisible || window.isVisible else { return }
        isVisible = false

        guard animated else {
            window.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                guard !self.isVisible else { return }
                self.window.orderOut(nil)
                self.window.alphaValue = 1
            }
        }
    }

    private func animateWindowAppearance() {
        let finalFrame = window.frame
        let startFrame = scaledFrame(from: finalFrame, scale: 0.96).offsetBy(dx: 0, dy: -4)
        let overshootFrame = scaledFrame(from: finalFrame, scale: 1.015).offsetBy(dx: 0, dy: 2)

        window.isProgrammaticallyMoving = true
        window.alphaValue = 0
        window.setFrame(startFrame, display: true)
        orderWindowFront()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(overshootFrame, display: true)
        } completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().setFrame(finalFrame, display: true)
                } completionHandler: {
                    Task { @MainActor in
                        self.window.isProgrammaticallyMoving = false
                    }
                }
            }
        }
    }

    /// Delete with a small pop-and-tuck motion. The window is fully
    /// transparent before it is ordered out, so its cosmetic state can be
    /// reset without flashing back on screen.
    private func animateWindowDisappearance(completion: @escaping @MainActor @Sendable () -> Void) {
        guard window.isVisible else {
            completion()
            return
        }

        window.isProgrammaticallyMoving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                completion()
                self.window.alphaValue = 1
                self.window.isProgrammaticallyMoving = false
            }
        }
    }

    private func scaledFrame(from frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: frame.midX - frame.width * scale / 2,
            y: frame.midY - frame.height * scale / 2,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func orderWindowFront() {
        if store.note.displayMode == .unpinned {
            window.orderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close(animated: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil) {
        window.delegate = nil
        let finish: @MainActor @Sendable () -> Void = { [window, completion] in
            window.orderOut(nil)
            window.close()
            completion?()
        }

        guard animated else {
            finish()
            return
        }

        animateWindowDisappearance(completion: finish)
    }

    func hide() {
        captureCurrentFrame()
        isManuallyHidden = true
        isVisible = false
        window.orderOut(nil)
    }

    private func moveExpandedFrameToCollapsedOrigin() {
        let previousFrame = store.note.expandedFrame.cgRect
        let dotOrigin = dotOrigin(forCollapsedWindowFrame: window.frame)
        let frame = CGRect(
            x: dotOrigin.x - previousFrame.width / 2 + NoteView.collapsedDotSize / 2,
            y: dotOrigin.y - previousFrame.height / 2 + NoteView.collapsedDotSize / 2,
            width: previousFrame.width,
            height: previousFrame.height
        )
        updateStoredFrameWithoutRefreshingContent {
            store.updateExpandedFrame(placementManager.clampedFrame(frame))
        }
    }

    private func updateStoredFrameWithoutRefreshingContent(_ update: () -> Void) {
        let wasApplyingTransition = isApplyingTransition
        isApplyingTransition = true
        update()
        isApplyingTransition = wasApplyingTransition
    }

    private func finishTransitionAfterAnimation() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            self.isApplyingTransition = false
        }
    }

    private static func windowFrame(forNoteFrame noteFrame: CGRect) -> CGRect {
        return CGRect(
            x: noteFrame.minX,
            y: noteFrame.minY,
            width: noteFrame.width,
            height: noteFrame.height
        )
    }

    private static func noteFrame(forWindowFrame windowFrame: CGRect) -> CGRect {
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: max(NoteView.resizableFloorSize, windowFrame.width),
            height: max(NoteView.resizableFloorSize, windowFrame.height)
        )
    }

    private func applyPresentationChangeIfNeeded(_ note: StickerNote) {
        guard !isApplyingTransition else { return }
        guard !window.isProgrammaticallyMoving else { return }

        let nextSnapshot = PresentationSnapshot(note: note)
        guard nextSnapshot != presentationSnapshot else { return }

        if nextSnapshot.displayMode != presentationSnapshot.displayMode {
            window.applyLevel(for: note.displayMode)
            if note.displayMode != .unpinned, window.isVisible {
                orderWindowFront()
            }
        }

        if nextSnapshot.isCollapsed != presentationSnapshot.isCollapsed {
            applyContent(animated: true)
            return
        }

        presentationSnapshot = nextSnapshot

        // A hidden stack sibling's note keeps its `expandedFrame` in sync via
        // `syncStackFrames` while the front note is dragged/resized, purely
        // as stored state. Actually moving its (ordered-out) window here too
        // can make it flash back into view mid-drag, trailing behind the
        // front note. Skip the live window update while hidden - `show()`
        // already applies the current `store.note` frame via `applyContent`
        // whenever this note becomes visible again.
        guard window.isVisible else { return }

        window.isProgrammaticallyMoving = true
        if note.isCollapsed {
            let dotOrigin = placementManager.clampedDotOrigin(note.collapsedOrigin.cgPoint)
            window.setFrame(collapsedWindowFrame(forDotOrigin: dotOrigin), display: true)
        } else {
            let frame = placementManager.clampedFrame(note.expandedFrame.cgRect)
            window.setFrame(Self.windowFrame(forNoteFrame: frame), display: true)
        }
        window.isProgrammaticallyMoving = false
    }

    private func collapsedWindowFrame(forDotOrigin dotOrigin: CGPoint) -> CGRect {
        CGRect(
            x: dotOrigin.x - collapsedWindowInset,
            y: dotOrigin.y - collapsedWindowInset,
            width: NoteView.collapsedDotHitSize,
            height: NoteView.collapsedDotHitSize
        )
    }

    private func dotOrigin(forCollapsedWindowFrame frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + collapsedWindowInset, y: frame.minY + collapsedWindowInset)
    }
}

private struct PresentationSnapshot: Equatable {
    let isCollapsed: Bool
    let expandedFrame: CodableRect
    let collapsedOrigin: CodablePoint
    let displayMode: NoteDisplayMode

    init(note: StickerNote) {
        isCollapsed = note.isCollapsed
        expandedFrame = note.expandedFrame
        collapsedOrigin = note.collapsedOrigin
        displayMode = note.displayMode
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    private var hoverTrackingArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureClearLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        get { false }
        set {}
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureClearLayer()
        updateHoverTrackingArea()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point)
    }

    override func magnify(with event: NSEvent) {
        let handled = (window as? StickerNoteWindow)?.trackPinchMagnification(event) ?? false
        if !handled {
            super.magnify(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateHoverTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        (window as? StickerNoteWindow)?.prepareForHoverGesture()
        super.mouseEntered(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }

    private func updateHoverTrackingArea() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    private func configureClearLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func draw(_ dirtyRect: NSRect) {}

}
