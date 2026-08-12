import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {
    private static let toolbarHeight: CGFloat = NoteView.toolbarHeight

    let store: NoteStore
    private let newNote: () -> Void
    private let deleteNote: (UUID) -> Void
    private let activateNote: (UUID) -> Void
    private let noteFrameChanged: () -> Void
    private let visibilityContext: () -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>)
    private let window: StickerNoteWindow
    private let placementManager = WindowPlacementManager()
    private var noteObserver: AnyCancellable?
    private var isApplyingTransition = false
    private var isRefreshingVisibility = false
    private var isManuallyHidden = false
    private var isVisible = false
    private var presentationSnapshot: PresentationSnapshot
    private let overlapState = NoteOverlapState()

    init(
        store: NoteStore,
        newNote: @escaping () -> Void,
        deleteNote: @escaping (UUID) -> Void,
        activateNote: @escaping (UUID) -> Void,
        noteFrameChanged: @escaping () -> Void,
        visibilityContext: @escaping () -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>)
    ) {
        self.store = store
        self.newNote = newNote
        self.deleteNote = deleteNote
        self.activateNote = activateNote
        self.noteFrameChanged = noteFrameChanged
        self.visibilityContext = visibilityContext
        let initialFrame = Self.windowFrame(forNoteFrame: placementManager.clampedFrame(store.note.expandedFrame.cgRect))
        window = StickerNoteWindow(frame: initialFrame)
        presentationSnapshot = PresentationSnapshot(note: store.note)
        super.init()
        window.delegate = self
        window.noteMouseDownHandler = { [weak self] in
            self?.selectAndBringToFront()
        }
        window.noteShortcutHandler = { [weak self] shortcut in
            guard let self else { return false }
            switch shortcut {
            case .closeNote:
                self.hide()
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

    func show(forceVisible: Bool = false, resetManualHidden: Bool = true) {
        if resetManualHidden {
            isManuallyHidden = false
        }
        applyContent()
        if forceVisible {
            if !isManuallyHidden {
                showWindow(animated: false)
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
        isApplyingTransition = false
    }

    func captureCurrentFrame() {
        updateStoredFrameWithoutRefreshingContent {
            captureCurrentFrameWithoutRefreshGuard()
        }
    }

    private func captureCurrentFrameWithoutRefreshGuard() {
        if store.note.isCollapsed {
            store.updateCollapsedOrigin(window.frame.origin)
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

    func windowDidMove(_ notification: Notification) {
        guard !collapseIfNeededFromCurrentWindowFrame() else { return }
        captureCurrentFrame()
        noteFrameChanged()
    }

    func windowDidResize(_ notification: Notification) {
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
        window.orderFrontRegardless()
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

    private func selectAndBringToFront() {
        activateNote(store.note.id)
        bringToFront()
    }

    private func applyContent(animated: Bool = false) {
        presentationSnapshot = PresentationSnapshot(note: store.note)

        if store.note.isCollapsed {
            let dotOrigin = placementManager.clampedDotOrigin(store.note.collapsedOrigin.cgPoint)
            window.applyCollapsedStyle()
            setFrame(CGRect(origin: dotOrigin, size: CGSize(width: 28, height: 28)), animated: animated, isCollapsing: true)
            window.contentView = ClearHostingView(allowsTransparentTopHitTesting: true, rootView: DotView(store: store, overlapState: overlapState) { [weak self] in
                self?.toggleCollapsed()
            })
        } else {
            let frame = placementManager.clampedFrame(store.note.expandedFrame.cgRect)
            window.applyExpandedStyle()
            setFrame(Self.windowFrame(forNoteFrame: frame), animated: animated, isCollapsing: false)
            window.contentView = ClearHostingView(allowsTransparentTopHitTesting: false, rootView: NoteView(
                store: store,
                overlapState: overlapState,
                newNote: newNote,
                deleteNote: { [deleteNote, store] in deleteNote(store.note.id) }
            ) { [weak self] in
                self?.toggleCollapsed()
            })
        }
    }

    private func setFrame(_ frame: CGRect, animated: Bool, isCollapsing: Bool) {
        guard animated else {
            window.setFrame(frame, display: true)
            return
        }

        if isCollapsing {
            let loweredFrame = frame.offsetBy(dx: 0, dy: -7)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(loweredFrame, display: true)
            } completionHandler: {
                Task { @MainActor in
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.window.animator().setFrame(frame, display: true)
                    }
                }
            }
            return
        }

        let overshoot = frame.insetBy(dx: -min(frame.width * 0.035, 10), dy: -min(frame.height * 0.035, 10))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(overshoot, display: true)
        } completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.window.animator().setFrame(frame, display: true)
                }
            }
        }
    }

    private func captureExpandedFrameIfNeeded() {
        guard !window.frame.size.equalTo(CGSize(width: 28, height: 28)) else { return }
        let noteFrame = Self.noteFrame(forWindowFrame: window.frame)
        updateStoredFrameWithoutRefreshingContent {
            store.updateExpandedFrame(noteFrame)
            store.updateCollapsedOrigin(CGPoint(x: noteFrame.midX - 14, y: noteFrame.midY - 14))
        }
    }

    private func collapseFromResizeToDefaultSize() {
        let collapsedOrigin = placementManager.clampedDotOrigin(
            CGPoint(x: window.frame.midX - 14, y: window.frame.midY - 14)
        )
        let restoreFrame = defaultSizedFrame(centeredOn: collapsedOrigin)

        isApplyingTransition = true
        store.updateExpandedFrame(restoreFrame)
        store.updateCollapsedOrigin(collapsedOrigin)
        store.updateCollapsed(true)
        applyContent(animated: true)
        isApplyingTransition = false
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
            x: dotOrigin.x + 14 - size.width / 2,
            y: dotOrigin.y + 14 - size.height / 2,
            width: size.width,
            height: size.height
        )
        return placementManager.clampedFrame(frame)
    }

    private func shouldCollapseFromResize(_ noteFrame: CGRect) -> Bool {
        let baseArea = NoteView.minimumNoteWidth * NoteView.minimumNoteHeight
        let reachedSingleAxisThreshold = noteFrame.width <= NoteView.collapseAxisThreshold
            || noteFrame.height <= NoteView.collapseAxisThreshold
        let reachedResizeFloor = noteFrame.height <= NoteView.resizableFloorSize + 1
            || noteFrame.width <= NoteView.resizableFloorSize + 1
        return reachedSingleAxisThreshold
            || reachedResizeFloor
            || noteFrame.width * noteFrame.height < baseArea * NoteView.collapseAreaRatio
    }

    private func showWindow(animated: Bool) {
        guard !isVisible || !window.isVisible else {
            return
        }

        isVisible = true
        guard animated else {
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func hideWindow(animated: Bool) {
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

    func close() {
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    func hide() {
        captureCurrentFrame()
        isManuallyHidden = true
        isVisible = false
        window.orderOut(nil)
    }

    private func moveExpandedFrameToCollapsedOrigin() {
        let previousFrame = store.note.expandedFrame.cgRect
        let dotOrigin = window.frame.origin
        let frame = CGRect(
            x: dotOrigin.x - previousFrame.width / 2 + 14,
            y: dotOrigin.y - previousFrame.height / 2 + 14,
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

    private static func windowFrame(forNoteFrame noteFrame: CGRect) -> CGRect {
        return CGRect(
            x: noteFrame.minX,
            y: noteFrame.minY,
            width: noteFrame.width,
            height: noteFrame.height + toolbarHeight
        )
    }

    private static func noteFrame(forWindowFrame windowFrame: CGRect) -> CGRect {
        return CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: max(NoteView.resizableFloorSize, windowFrame.width),
            height: max(NoteView.resizableFloorSize, windowFrame.height - toolbarHeight)
        )
    }

    private func applyPresentationChangeIfNeeded(_ note: StickerNote) {
        let nextSnapshot = PresentationSnapshot(note: note)
        guard nextSnapshot != presentationSnapshot else { return }

        if nextSnapshot.isCollapsed != presentationSnapshot.isCollapsed {
            applyContent(animated: true)
            return
        }

        presentationSnapshot = nextSnapshot
        if note.isCollapsed {
            let dotOrigin = placementManager.clampedDotOrigin(note.collapsedOrigin.cgPoint)
            window.setFrame(CGRect(origin: dotOrigin, size: CGSize(width: 28, height: 28)), display: true)
        } else {
            let frame = placementManager.clampedFrame(note.expandedFrame.cgRect)
            window.setFrame(Self.windowFrame(forNoteFrame: frame), display: true)
        }
    }
}

private struct PresentationSnapshot: Equatable {
    let isCollapsed: Bool
    let expandedFrame: CodableRect
    let collapsedOrigin: CodablePoint

    init(note: StickerNote) {
        isCollapsed = note.isCollapsed
        expandedFrame = note.expandedFrame
        collapsedOrigin = note.collapsedOrigin
    }
}

private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    private let allowsTransparentTopHitTesting: Bool

    required init(rootView: Content) {
        self.allowsTransparentTopHitTesting = true
        super.init(rootView: rootView)
        configureClearLayer()
    }

    init(allowsTransparentTopHitTesting: Bool = true, rootView: Content) {
        self.allowsTransparentTopHitTesting = allowsTransparentTopHitTesting
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
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !allowsTransparentTopHitTesting else {
            return super.hitTest(point)
        }

        let noteTopY = max(0, bounds.height - NoteView.toolbarHeight)
        if point.y > noteTopY {
            return super.hitTest(point).flatMap { hitView in
                guard isLikelyToolbarHit(hitView) else {
                    return nil
                }
                return hitView
            }
        }

        return super.hitTest(point)
    }

    private func configureClearLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func draw(_ dirtyRect: NSRect) {}

    private func isLikelyToolbarHit(_ view: NSView) -> Bool {
        guard view !== self else {
            return false
        }

        var current: NSView? = view
        while let candidate = current, candidate !== self {
            if NSStringFromClass(type(of: candidate)).contains("Button")
                || NSStringFromClass(type(of: candidate)).contains("Menu") {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}
