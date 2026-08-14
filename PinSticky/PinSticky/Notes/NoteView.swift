import AppKit
import SwiftUI

struct NoteView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var overlapState: NoteOverlapState
    @ObservedObject var selectionState: NoteSelectionState
    let newNote: () -> Void
    let deleteNote: () -> Void
    let collapse: () -> Void
    let attachmentDragSucceeded: () -> Void
    let attachNotes: (RunningApplicationInfo?) -> Void
    let unpinNotes: () -> Void
    let updateThemeForSelection: (String) -> Void
    let updateFontSizeForSelection: (Double) -> Void
    let collapseSelection: () -> Void

    static let minimumNoteWidth: CGFloat = 270
    static let minimumNoteHeight: CGFloat = 170
    static let resizableFloorSize: CGFloat = 80
    static let collapseAreaRatio: CGFloat = 0.25
    static let collapseAxisThreshold: CGFloat = resizableFloorSize + 24
    static let toolbarMinimumVisibleWidth: CGFloat = 250
    static let toolbarCompressedWidth: CGFloat = 195
    static let toolbarHeight: CGFloat = 36
    static let collapsedDotSize: CGFloat = 28
    static let collapsedDotVisualSize: CGFloat = 24
    static let collapsedDotHitSize: CGFloat = 44

    private var theme: NoteTheme {
        BuiltInThemes.theme(id: store.note.themeID)
    }

    private var noteOpacity: Double {
        StickerNote.clampedOpacity(store.note.opacity)
    }

    private var usesLiquidGlass: Bool {
        store.note.usesLiquidGlass
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NoteBackground(theme: theme, opacity: noteOpacity, usesLiquidGlass: usesLiquidGlass)
                    .overlay {
                        if overlapState.hasOverlap {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.72), lineWidth: 0.75, antialiased: true)
                        }
                    }

                VStack(spacing: 0) {
                    header(width: geometry.size.width)

                    NoteRichTextEditor(store: store, theme: theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.clear)
    }

    @ViewBuilder
    private func header(width: CGFloat) -> some View {
        HStack {
            Spacer(minLength: 8)
            if width >= Self.toolbarMinimumVisibleWidth {
                NoteHoverControls(
                    store: store,
                    selectionState: selectionState,
                    theme: theme,
                    newNote: newNote,
                    deleteNote: deleteNote,
                    collapse: collapse,
                    attachmentDragSucceeded: attachmentDragSucceeded,
                    attachNotes: attachNotes,
                    unpinNotes: unpinNotes,
                    updateThemeForSelection: updateThemeForSelection,
                    updateFontSizeForSelection: updateFontSizeForSelection,
                    collapseSelection: collapseSelection
                )
            } else {
                HeaderOverflowDots(color: theme.foregroundColor)
            }
        }
        .frame(height: Self.toolbarHeight)
        .padding(.horizontal, 8)
    }
}

private struct HeaderOverflowDots: View {
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { _ in
                Circle()
                    .fill(color.opacity(0.72))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.16), lineWidth: 1))
    }
}

private struct NoteHoverControls: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var selectionState: NoteSelectionState
    let theme: NoteTheme
    let newNote: () -> Void
    let deleteNote: () -> Void
    let collapse: () -> Void
    let attachmentDragSucceeded: () -> Void
    let attachNotes: (RunningApplicationInfo?) -> Void
    let unpinNotes: () -> Void
    let updateThemeForSelection: (String) -> Void
    let updateFontSizeForSelection: (Double) -> Void
    let collapseSelection: () -> Void
    @State private var characterAttributeState = CharacterAttributeState()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                selectionState.toggle(store.note.id)
            } label: {
                Image(systemName: selectionState.isSelected(store.note.id) ? "checkmark.square.fill" : "square")
            }
            .help(selectionState.isSelected(store.note.id) ? "선택 해제" : "메모 선택")

            Button(action: newNote) {
                Image(systemName: "plus")
            }

            Button(action: deleteNote) {
                Image(systemName: "xmark")
            }

            appPinningMenu

            themeMenu

            characterAttributesMenu

            Button(action: { updateFontSizeForSelection(-1) }) {
                Image(systemName: "textformat.size.smaller")
            }

            Button(action: { updateFontSizeForSelection(1) }) {
                Image(systemName: "textformat.size.larger")
            }

            Button(action: collapseSelection) {
                Image(systemName: "circle.fill")
            }
            .onHover { isHovering in
                if isHovering {
                    NSCursor.arrow.set()
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(theme.foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.foregroundColor.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(theme.foregroundColor.opacity(0.18), lineWidth: 1))
    }

    private var themeMenu: some View {
        ThemeSelectionButton(
            store: store,
            theme: theme,
            updateThemeForSelection: updateThemeForSelection
        )
            .frame(width: 15, height: 15)
    }

    private var characterAttributesMenu: some View {
        Menu {
            Button {
                requestCharacterAttribute(.bold)
            } label: {
                characterAttributeLabel(
                    title: store.language.text(.bold),
                    systemImage: "bold",
                    isActive: characterAttributeState.bold
                )
            }

            Button {
                requestCharacterAttribute(.underline)
            } label: {
                characterAttributeLabel(
                    title: store.language.text(.underline),
                    systemImage: "underline",
                    isActive: characterAttributeState.underline
                )
            }

            Button {
                requestCharacterAttribute(.strikethrough)
            } label: {
                characterAttributeLabel(
                    title: store.language.text(.strikethrough),
                    systemImage: "strikethrough",
                    isActive: characterAttributeState.strikethrough
                )
            }

        } label: {
            Image(systemName: "textformat")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onReceive(NotificationCenter.default.publisher(for: .pinStickyCharacterAttributeStateChanged)) { notification in
            guard let noteID = notification.userInfo?["noteID"] as? UUID,
                  noteID == store.note.id else { return }
            characterAttributeState = CharacterAttributeState(
                bold: notification.userInfo?["bold"] as? Bool ?? false,
                underline: notification.userInfo?["underline"] as? Bool ?? false,
                strikethrough: notification.userInfo?["strikethrough"] as? Bool ?? false
            )
        }
    }

    @ViewBuilder
    private func characterAttributeLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        Label(isActive ? "\(title)  ✓" : title, systemImage: systemImage)
    }

    private func requestCharacterAttribute(_ action: NoteCharacterAttributeAction) {
        NotificationCenter.default.post(
            name: .pinStickyCharacterAttributeRequested,
            object: nil,
            userInfo: [
                "noteID": store.note.id,
                "action": action.rawValue
            ]
        )
    }

    private var appPinningMenu: some View {
        PinAttachmentButton(
            store: store,
            theme: theme,
            attachmentDragSucceeded: attachmentDragSucceeded,
            attachNotes: attachNotes,
            unpinNotes: unpinNotes
        )
            .frame(width: 15, height: 15)
    }

    private var currentPinningDescription: String {
        guard store.note.displayMode == .whenAppIsActive else {
            if store.note.displayMode == .unpinned {
                return store.language.text(.unpinned)
            }
            return store.language.text(.alwaysVisible)
        }

        let appName = store.note.attachedAppName ?? store.note.attachedBundleIdentifier ?? store.language.text(.notAttached)
        return "\(store.language.text(.attachedTo)): \(appName)"
    }
}

private struct PinAttachmentButton: NSViewRepresentable {
    @ObservedObject var store: NoteStore
    let theme: NoteTheme
    let attachmentDragSucceeded: () -> Void
    let attachNotes: (RunningApplicationInfo?) -> Void
    let unpinNotes: () -> Void

    func makeNSView(context: Context) -> DraggablePinButton {
        let button = DraggablePinButton(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ button: DraggablePinButton, context: Context) {
        button.image = NSImage(systemSymbolName: store.note.displayMode == .whenAppIsActive ? "pin.fill" : "pin", accessibilityDescription: nil)
        button.contentTintColor = NSColor(hex: theme.foreground)
        button.onClick = { [weak store] sourceView in
            guard let store, sourceView.window != nil else { return }
            makeMenu(for: store).popUp(positioning: nil, at: NSPoint(x: -8, y: sourceView.bounds.maxY + 6), in: sourceView)
        }
        button.onDragEnd = {
            guard let application = ApplicationDropTargetResolver.applicationUnderMouse() else { return }
            attachNotes(application)
            attachmentDragSucceeded()
        }
    }

    private func makeMenu(for store: NoteStore) -> NSMenu {
        let menu = NSMenu()

        let currentModeHeader = NSMenuItem(title: store.language.text(.currentMode), action: nil, keyEquivalent: "")
        currentModeHeader.isEnabled = false
        menu.addItem(currentModeHeader)

        let currentModeItem = NSMenuItem(title: currentPinningDescription(for: store), action: nil, keyEquivalent: "")
        currentModeItem.isEnabled = false
        menu.addItem(currentModeItem)
        menu.addItem(.separator())

        let alwaysItem = PinAttachmentMenuItem(title: store.language.text(.alwaysVisible)) {
            attachNotes(nil)
        }
        alwaysItem.state = store.note.displayMode == .always ? .on : .off
        menu.addItem(alwaysItem)

        let unpinnedItem = PinAttachmentMenuItem(title: store.language.text(.unpinned)) {
            unpinNotes()
        }
        unpinnedItem.state = store.note.displayMode == .unpinned ? .on : .off
        menu.addItem(unpinnedItem)

        menu.addItem(.separator())

        runningApps.forEach { app in
            let item = PinAttachmentMenuItem(title: app.name) {
                attachNotes(app)
            }
            item.state = store.note.attachedBundleIdentifier == app.bundleIdentifier ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    private func currentPinningDescription(for store: NoteStore) -> String {
        guard store.note.displayMode == .whenAppIsActive else {
            if store.note.displayMode == .unpinned {
                return store.language.text(.unpinned)
            }
            return store.language.text(.alwaysVisible)
        }

        let appName = store.note.attachedAppName ?? store.note.attachedBundleIdentifier ?? store.language.text(.notAttached)
        return "\(store.language.text(.attachedTo)): \(appName)"
    }

    private var runningApps: [RunningApplicationInfo] {
        NSWorkspace.shared.runningApplications
            .compactMap { app in
                RunningApplicationInfo(application: app)
            }
            .sorted {
                $0.name < $1.name
            }
    }
}

private struct ThemeSelectionButton: NSViewRepresentable {
    @ObservedObject var store: NoteStore
    let theme: NoteTheme
    let updateThemeForSelection: (String) -> Void

    func makeNSView(context: Context) -> MenuIconButton {
        let button = MenuIconButton(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ button: MenuIconButton, context: Context) {
        button.image = NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: nil)
        button.contentTintColor = NSColor(hex: theme.foreground)
        button.onClick = { sourceView in
            guard sourceView.window != nil else { return }
            makeMenu().popUp(positioning: nil, at: NSPoint(x: -8, y: sourceView.bounds.maxY + 6), in: sourceView)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        BuiltInThemes.all.forEach { candidate in
            let item = PinAttachmentMenuItem(title: candidate.displayName(language: store.language)) {
                updateThemeForSelection(candidate.id)
            }
            item.image = themeSwatchImage(candidate)
            item.state = store.note.themeID == candidate.id ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func themeSwatchImage(_ theme: NoteTheme) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor(hex: theme.background).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3).stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private final class MenuIconButton: NSButton {
    var onClick: ((NSView) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }
}

private final class DraggablePinButton: NSButton {
    var onClick: ((NSView) -> Void)?
    var onDragEnd: (() -> Void)?
    private var dragPreview: PinDragPreviewWindow?

    override func mouseDown(with event: NSEvent) {
        let dragThreshold: CGFloat = 7
        let startScreenPoint = NSEvent.mouseLocation
        var didDrag = false

        while true {
            guard let nextEvent = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                alphaValue = 1
                return
            }

            let current = NSEvent.mouseLocation
            let distance = hypot(current.x - startScreenPoint.x, current.y - startScreenPoint.y)

            switch nextEvent.type {
            case .leftMouseDragged:
                guard didDrag || distance > dragThreshold else { continue }
                if !didDrag {
                    didDrag = true
                    alphaValue = 0.36
                    dragPreview = PinDragPreviewWindow(
                        image: image,
                        tintColor: contentTintColor ?? .labelColor
                    )
                }
                dragPreview?.move(to: current)
            case .leftMouseUp:
                dragPreview?.close()
                dragPreview = nil
                alphaValue = 1
                if didDrag {
                    onDragEnd?()
                } else {
                    onClick?(self)
                }
                return
            default:
                break
            }
        }
    }
}

private final class PinDragPreviewWindow: NSPanel {
    private let sideLength: CGFloat = 28

    init(image: NSImage?, tintColor: NSColor) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: sideLength, height: sideLength),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: sideLength, height: sideLength))
        imageView.image = image
        imageView.contentTintColor = tintColor
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let container = NSView(frame: NSRect(x: 0, y: 0, width: sideLength, height: sideLength))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(imageView)
        contentView = container
    }

    func move(to mouseLocation: CGPoint) {
        setFrameOrigin(CGPoint(
            x: mouseLocation.x - sideLength / 2,
            y: mouseLocation.y - sideLength - 4
        ))
        orderFrontRegardless()
    }
}

@MainActor
private final class PinAttachmentMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        Task { @MainActor in
            handler()
        }
    }
}

struct RunningApplicationInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String

    init?(applicationPID pid: pid_t) {
        guard let application = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) else {
            return nil
        }
        self.init(application: application)
    }

    init?(application: NSRunningApplication) {
        guard application.activationPolicy == .regular,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let appBundleURL = application.bundleURL,
              appBundleURL != Bundle.main.bundleURL,
              let bundleIdentifier = Self.bundleIdentifier(inAppBundleAt: appBundleURL) else {
            return nil
        }

        self.id = bundleIdentifier
        self.name = application.localizedName ?? bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    private static func bundleIdentifier(inAppBundleAt appBundleURL: URL) -> String? {
        let infoPlistURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let dictionary = NSDictionary(contentsOf: infoPlistURL),
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            return nil
        }
        return bundleIdentifier
    }
}

private enum ApplicationDropTargetResolver {
    static func applicationUnderMouse() -> RunningApplicationInfo? {
        let mouseLocation = NSEvent.mouseLocation
        let windowPoint = cgWindowPoint(from: mouseLocation)

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowInfoList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  windowInfo[kCGWindowLayer as String] as? Int == 0,
                  (windowInfo[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = windowBounds(from: windowInfo),
                  bounds.contains(windowPoint),
                  let application = NSRunningApplication(processIdentifier: ownerPID),
                  !application.isTerminated,
                  !application.isHidden else {
                continue
            }

            return RunningApplicationInfo(application: application)
        }

        return nil
    }

    private static func cgWindowPoint(from appKitPoint: CGPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return appKitPoint }
        return CGPoint(
            x: appKitPoint.x,
            y: mainScreen.frame.maxY - appKitPoint.y
        )
    }

    private static func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
        if let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary {
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds) else {
                return nil
            }
            return bounds
        }

        if let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
           let x = boundsDictionary["X"],
           let y = boundsDictionary["Y"],
           let width = boundsDictionary["Width"],
           let height = boundsDictionary["Height"] {
            return CGRect(x: x, y: y, width: width, height: height)
        }

        return nil
    }
}

struct DotView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var overlapState: NoteOverlapState
    let expand: () -> Void
    let dragEnded: () -> Void

    private var theme: NoteTheme {
        BuiltInThemes.theme(id: store.note.themeID)
    }

    private var dotOpacity: Double {
        StickerNote.clampedOpacity(store.note.opacity)
    }

    private var usesLiquidGlass: Bool {
        store.note.usesLiquidGlass
    }

    var body: some View {
        ZStack {
            DotBackground(theme: theme, opacity: dotOpacity, usesLiquidGlass: usesLiquidGlass)
                .overlay {
                    if overlapState.hasOverlap {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.76), lineWidth: 0.75, antialiased: true)
                    }
                }
                .frame(width: NoteView.collapsedDotVisualSize, height: NoteView.collapsedDotVisualSize)
            DotInteractionView(expand: expand, dragEnded: dragEnded)
                .frame(width: NoteView.collapsedDotHitSize, height: NoteView.collapsedDotHitSize)
        }
        .frame(width: NoteView.collapsedDotHitSize, height: NoteView.collapsedDotHitSize)
    }
}

private struct NoteBackground: View {
    let theme: NoteTheme
    let opacity: Double
    let usesLiquidGlass: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            if usesLiquidGlass, #available(macOS 26.0, *) {
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)
                    shape
                        .fill(theme.backgroundColor.opacity(max(0.30, opacity * 0.54)))
                    shape
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                }
                .glassEffect(.regular.tint(theme.backgroundColor.opacity(0.34)), in: shape)
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .opacity(1 - opacity)
                shape
                    .fill(theme.backgroundColor.opacity(opacity))
            }
        }
    }
}

private struct DotBackground: View {
    let theme: NoteTheme
    let opacity: Double
    let usesLiquidGlass: Bool

    var body: some View {
        ZStack {
            if usesLiquidGlass, #available(macOS 26.0, *) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                    Circle()
                        .fill(theme.backgroundColor.opacity(max(0.30, opacity * 0.54)))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                }
                .glassEffect(.regular.tint(theme.backgroundColor.opacity(0.34)), in: Circle())
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(1 - opacity)
                Circle()
                    .fill(theme.backgroundColor.opacity(opacity))
            }
        }
    }
}

final class NoteOverlapState: ObservableObject {
    @Published var hasOverlap = false
}

final class NoteSelectionState: ObservableObject {
    @Published private(set) var selectedNoteIDs: Set<UUID> = []

    func isSelected(_ noteID: UUID) -> Bool {
        selectedNoteIDs.contains(noteID)
    }

    func toggle(_ noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    func remove(_ noteID: UUID) {
        selectedNoteIDs.remove(noteID)
    }

    func prune(activeNoteIDs: Set<UUID>) {
        selectedNoteIDs = selectedNoteIDs.intersection(activeNoteIDs)
    }
}

private struct DotInteractionView: NSViewRepresentable {
    let expand: () -> Void
    let dragEnded: () -> Void

    func makeNSView(context: Context) -> DotInteractionNSView {
        DotInteractionNSView(expand: expand, dragEnded: dragEnded)
    }

    func updateNSView(_ nsView: DotInteractionNSView, context: Context) {
        nsView.expand = expand
        nsView.dragEnded = dragEnded
    }
}

private final class DotInteractionNSView: NSView {
    var expand: () -> Void
    var dragEnded: () -> Void

    private var startOrigin = CGPoint.zero
    private var startScreenPoint = CGPoint.zero
    private var didDrag = false

    init(expand: @escaping () -> Void, dragEnded: @escaping () -> Void) {
        self.expand = expand
        self.dragEnded = dragEnded
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        startOrigin = window?.frame.origin ?? .zero
        startScreenPoint = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let delta = CGPoint(
            x: current.x - startScreenPoint.x,
            y: current.y - startScreenPoint.y
        )
        guard didDrag || hypot(delta.x, delta.y) > 9 else { return }
        didDrag = true
        window.setFrameOrigin(CGPoint(
            x: startOrigin.x + delta.x,
            y: startOrigin.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            dragEnded()
        } else {
            expand()
        }
    }
}
