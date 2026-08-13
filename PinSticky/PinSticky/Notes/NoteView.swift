import AppKit
import SwiftUI

struct NoteView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var overlapState: NoteOverlapState
    let newNote: () -> Void
    let deleteNote: () -> Void
    let collapse: () -> Void

    static let minimumNoteWidth: CGFloat = 270
    static let minimumNoteHeight: CGFloat = 170
    static let resizableFloorSize: CGFloat = 80
    static let collapseAreaRatio: CGFloat = 0.25
    static let collapseAxisThreshold: CGFloat = resizableFloorSize + 24
    static let toolbarMinimumVisibleWidth: CGFloat = 225
    static let toolbarCompressedWidth: CGFloat = 170
    static let toolbarHeight: CGFloat = 36
    static let collapsedDotSize: CGFloat = 28
    static let collapsedDotVisualSize: CGFloat = 24
    static let collapsedDotHitSize: CGFloat = 44

    private var theme: NoteTheme {
        BuiltInThemes.theme(id: store.note.themeID)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.backgroundColor)
                    .overlay {
                        if overlapState.hasOverlap {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.72), lineWidth: 0.75, antialiased: true)
                        }
                    }

                VStack(spacing: 0) {
                    header(width: geometry.size.width)

                    NoteRichTextEditor(store: store, theme: theme)
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
                NoteHoverControls(store: store, theme: theme, newNote: newNote, deleteNote: deleteNote, collapse: collapse)
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
    let theme: NoteTheme
    let newNote: () -> Void
    let deleteNote: () -> Void
    let collapse: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: newNote) {
                Image(systemName: "plus")
            }

            Button(action: deleteNote) {
                Image(systemName: "xmark")
            }

            appPinningMenu

            themeMenu

            Button(action: { store.updateFontSize(store.note.fontSize - 1) }) {
                Image(systemName: "textformat.size.smaller")
            }

            Button(action: { store.updateFontSize(store.note.fontSize + 1) }) {
                Image(systemName: "textformat.size.larger")
            }

            Button(action: collapse) {
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
        Menu {
            ForEach(BuiltInThemes.all) { candidate in
                Button {
                    store.updateTheme(candidate.id)
                } label: {
                    HStack {
                        Circle()
                            .fill(candidate.backgroundColor)
                            .frame(width: 10, height: 10)
                        Text(candidate.displayName(language: store.language))
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var appPinningMenu: some View {
        Menu {
            Section(store.language.text(.currentMode)) {
                Text(currentPinningDescription)
            }

            Section(store.language.text(.pinMenu)) {
                Button {
                    store.setAlwaysVisible()
                } label: {
                    pinningLabel(
                        title: store.language.text(.alwaysVisible),
                        isSelected: store.note.displayMode == .always
                    )
                }

                ForEach(runningApps) { app in
                    Button {
                        store.attach(to: app)
                    } label: {
                        pinningLabel(
                            title: app.name,
                            isSelected: store.note.attachedBundleIdentifier == app.bundleIdentifier
                        )
                    }
                }
            }

            if store.note.displayMode == .whenAppIsActive {
                Section {
                    Button(store.language.text(.clearAttachment)) {
                        store.setAlwaysVisible()
                    }
                }
            }
        } label: {
            Image(systemName: store.note.displayMode == .whenAppIsActive ? "pin.fill" : "pin")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentPinningDescription: String {
        guard store.note.displayMode == .whenAppIsActive else {
            return store.language.text(.alwaysVisible)
        }

        let appName = store.note.attachedAppName ?? store.note.attachedBundleIdentifier ?? store.language.text(.notAttached)
        return "\(store.language.text(.attachedTo)): \(appName)"
    }

    @ViewBuilder
    private func pinningLabel(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
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

struct DotView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var overlapState: NoteOverlapState
    let expand: () -> Void
    let dragEnded: () -> Void

    private var theme: NoteTheme {
        BuiltInThemes.theme(id: store.note.themeID)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.backgroundColor)
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

final class NoteOverlapState: ObservableObject {
    @Published var hasOverlap = false
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
