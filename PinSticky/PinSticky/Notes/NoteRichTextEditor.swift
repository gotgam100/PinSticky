import AppKit
import SwiftUI

enum NoteCharacterAttributeAction: String {
    case bold
    case underline
    case strikethrough
}

extension Notification.Name {
    static let pinStickyCharacterAttributeRequested = Notification.Name("pinStickyCharacterAttributeRequested")
    static let pinStickyCharacterAttributeStateChanged = Notification.Name("pinStickyCharacterAttributeStateChanged")
}

struct NoteRichTextEditor: NSViewRepresentable {
    @ObservedObject var store: NoteStore
    let theme: NoteTheme

    func makeNSView(context: Context) -> PinStickyTextEditorContainer {
        let container = PinStickyTextEditorContainer()
        let textView = ContextMenuTextView()
        textView.owner = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.markedTextAttributes = [
            .underlineStyle: 0
        ]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = false
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width, .height]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false

        container.textView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(note: store.note, theme: theme)
        return container
    }

    func updateNSView(_ container: PinStickyTextEditorContainer, context: Context) {
        container.configureTextLayout()
        context.coordinator.apply(note: store.note, theme: theme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let store: NoteStore
        weak var textView: NSTextView?
        private var isApplying = false
        private var lastAppliedNoteID: UUID?
        private var lastAppliedThemeID: String?
        private var lastAppliedFontSize: Double?
        private var lastAppliedContent: String?

        init(store: NoteStore) {
            self.store = store
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleCharacterAttributeNotification(_:)),
                name: .pinStickyCharacterAttributeRequested,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func apply(note: StickerNote, theme: NoteTheme) {
            guard let textView else { return }

            let noteIdentityChanged = lastAppliedNoteID != note.id
            let themeChanged = lastAppliedThemeID != note.themeID
            let fontSizeChanged = lastAppliedFontSize != note.fontSize
            let contentChanged = lastAppliedContent != note.content

            guard noteIdentityChanged || themeChanged || fontSizeChanged || contentChanged else { return }

            isApplying = true
            let selectedRange = textView.selectedRange()
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: note.fontSize, weight: .medium),
                .foregroundColor: NSColor(hex: theme.foreground),
                .paragraphStyle: NSParagraphStyle.pinStickyDefault(fontSize: note.fontSize),
                .kern: 0
            ]
            textView.typingAttributes = defaultAttributes
            textView.defaultParagraphStyle = NSParagraphStyle.pinStickyDefault(fontSize: note.fontSize)
            textView.font = NSFont.systemFont(ofSize: note.fontSize, weight: .medium)
            textView.textColor = NSColor(hex: theme.foreground)

            if noteIdentityChanged || (!textView.isFirstResponderInWindow && textView.string != note.content) {
                let attributed = NSAttributedString(string: note.content, attributes: defaultAttributes)
                textView.textStorage?.setAttributedString(attributed)
                textView.setSelectedRange(NSRange(
                    location: min(selectedRange.location, attributed.length),
                    length: min(selectedRange.length, max(0, attributed.length - min(selectedRange.location, attributed.length)))
                ))
            } else if themeChanged || fontSizeChanged {
                let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
                if fullRange.length > 0 {
                    textView.textStorage?.addAttributes(defaultAttributes, range: fullRange)
                }
            }

            lastAppliedNoteID = note.id
            lastAppliedThemeID = note.themeID
            lastAppliedFontSize = note.fontSize
            lastAppliedContent = note.content
            isApplying = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            let content = textView.string
            store.updateContent(content)
            lastAppliedContent = content
            (textView.superview as? PinStickyTextEditorContainer)?.configureTextLayout()
            publishCharacterAttributeState()
        }

        func convertSelectionToTodo() {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserParagraphAttributeChange
            let nsString = textView.string as NSString
            let text = nsString.substring(with: targetRange)
            let converted = text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return line }
                    if trimmed.hasPrefix("○ ") || trimmed.hasPrefix("● ") {
                        return line
                    }
                    let leading = String(line.prefix { $0 == " " || $0 == "\t" })
                    return "\(leading)○ \(line.dropFirst(leading.count))"
                }
                .joined(separator: "\n")

            textView.insertText(converted, replacementRange: targetRange)
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
        }

        func removeTodoFormatFromSelection() {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserParagraphAttributeChange
            let nsString = textView.string as NSString
            let text = nsString.substring(with: targetRange)
            let converted = text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    let leading = String(line.prefix { $0 == " " || $0 == "\t" })
                    let body = line.dropFirst(leading.count)
                    if body.hasPrefix("○ ") || body.hasPrefix("● ") {
                        return "\(leading)\(body.dropFirst(2))"
                    }
                    return line
                }
                .joined(separator: "\n")

            textView.insertText(converted, replacementRange: targetRange)
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
        }

        func applyTextColor(_ color: NSColor) {
            guard let textView, let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserCharacterAttributeChange
            guard targetRange.length > 0 else {
                textView.typingAttributes[.foregroundColor] = color
                return
            }

            storage.addAttribute(.foregroundColor, value: color, range: targetRange)
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
        }

        func toggleBold() {
            applyBold(enabled: !currentCharacterAttributeState().bold)
        }

        func toggleUnderline() {
            applyCharacterAttribute(.underlineStyle, enabledValue: NSUnderlineStyle.single.rawValue)
        }

        func toggleStrikethrough() {
            applyCharacterAttribute(.strikethroughStyle, enabledValue: NSUnderlineStyle.single.rawValue)
        }

        @objc private func handleCharacterAttributeNotification(_ notification: Notification) {
            guard let noteID = notification.userInfo?["noteID"] as? UUID,
                  noteID == store.note.id,
                  let rawAction = notification.userInfo?["action"] as? String,
                  let action = NoteCharacterAttributeAction(rawValue: rawAction) else {
                return
            }

            textView?.window?.makeKey()
            textView?.window?.makeFirstResponder(textView)

            switch action {
            case .bold:
                toggleBold()
            case .underline:
                toggleUnderline()
            case .strikethrough:
                toggleStrikethrough()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            publishCharacterAttributeState()
        }

        private func applyBold(enabled: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserCharacterAttributeChange
            guard targetRange.length > 0 else {
                textView.typingAttributes[.font] = NSFont.systemFont(
                    ofSize: store.note.fontSize,
                    weight: enabled ? .bold : .medium
                )
                publishCharacterAttributeState()
                return
            }

            storage.enumerateAttribute(.font, in: targetRange) { value, range, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: store.note.fontSize, weight: .medium)
                let nextFont = NSFont.systemFont(
                    ofSize: font.pointSize,
                    weight: enabled ? .bold : .medium
                )
                storage.addAttribute(.font, value: nextFont, range: range)
            }
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
            publishCharacterAttributeState()
        }

        func applyLineSpacing(_ spacing: LineSpacingOption) {
            guard let textView, let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserParagraphAttributeChange
            let paragraphRange = (storage.string as NSString).paragraphRange(for: targetRange)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = spacing.value(fontSize: store.note.fontSize)
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            textView.typingAttributes[.paragraphStyle] = style
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
        }

        private func applyCharacterAttribute(_ key: NSAttributedString.Key, enabledValue: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let targetRange = selectedRange.length > 0 ? selectedRange : textView.rangeForUserCharacterAttributeChange
            guard targetRange.length > 0 else {
                let isEnabled = currentCharacterAttributeState().isEnabled(for: key)
                if isEnabled {
                    textView.typingAttributes.removeValue(forKey: key)
                } else {
                    textView.typingAttributes[key] = enabledValue
                }
                publishCharacterAttributeState()
                return
            }

            if currentCharacterAttributeState().isEnabled(for: key) {
                storage.removeAttribute(key, range: targetRange)
            } else {
                storage.addAttribute(key, value: enabledValue, range: targetRange)
            }
            store.updateContent(textView.string)
            lastAppliedContent = textView.string
            publishCharacterAttributeState()
        }

        private func currentCharacterAttributeState() -> CharacterAttributeState {
            guard let textView else { return CharacterAttributeState() }
            return textView.currentCharacterAttributeState
        }

        private func publishCharacterAttributeState() {
            let state = currentCharacterAttributeState()
            NotificationCenter.default.post(
                name: .pinStickyCharacterAttributeStateChanged,
                object: nil,
                userInfo: [
                    "noteID": store.note.id,
                    "bold": state.bold,
                    "underline": state.underline,
                    "strikethrough": state.strikethrough
                ]
            )
        }
    }
}

struct CharacterAttributeState: Equatable {
    var bold = false
    var underline = false
    var strikethrough = false

    func isEnabled(for key: NSAttributedString.Key) -> Bool {
        switch key {
        case .underlineStyle:
            return underline
        case .strikethroughStyle:
            return strikethrough
        default:
            return false
        }
    }
}

final class ContextMenuTextView: NSTextView {
    weak var owner: NoteRichTextEditor.Coordinator?
    private var trackingArea: NSTrackingArea?

    override func paste(_ sender: Any?) {
        guard let plainText = NSPasteboard.general.string(forType: .string),
              let owner else {
            super.paste(sender)
            return
        }

        typingAttributes = defaultTypingAttributes(for: owner)
        insertText(normalizedPlainText(plainText), replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        if let owner {
            typingAttributes = defaultTypingAttributes(for: owner)
        }
        super.insertNewline(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false

        let language = owner?.store.language ?? .korean

        let colorTitle = owner?.store.language.text(.textColor) ?? AppLanguage.korean.text(.textColor)
        let colorMenuItem = NSMenuItem(title: colorTitle, action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for option in TextColorOption.all {
            let item = NSMenuItem(title: option.title(language: language), action: #selector(applyColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.color
            item.image = option.swatchImage
            colorMenu.addItem(item)
        }
        colorMenuItem.submenu = colorMenu
        menu.addItem(colorMenuItem)

        let characterItem = NSMenuItem(title: language.text(.characterAttributes), action: nil, keyEquivalent: "")
        let characterMenu = NSMenu()
        let characterState = currentCharacterAttributeState
        characterMenu.addItem(actionItem(
            title: language.text(.bold),
            selector: #selector(toggleBold),
            systemImage: "bold",
            isChecked: characterState.bold
        ))
        characterMenu.addItem(actionItem(
            title: language.text(.underline),
            selector: #selector(toggleUnderline),
            systemImage: "underline",
            isChecked: characterState.underline
        ))
        characterMenu.addItem(actionItem(
            title: language.text(.strikethrough),
            selector: #selector(toggleStrikethrough),
            systemImage: "strikethrough",
            isChecked: characterState.strikethrough
        ))
        characterItem.submenu = characterMenu
        menu.addItem(characterItem)

        let paragraphItem = NSMenuItem(title: language.text(.paragraphAttributes), action: nil, keyEquivalent: "")
        let paragraphMenu = NSMenu()
        for option in LineSpacingOption.allCases {
            let item = NSMenuItem(title: option.title(language: language), action: #selector(applyLineSpacing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            paragraphMenu.addItem(item)
        }
        paragraphItem.submenu = paragraphMenu
        menu.addItem(paragraphItem)

        let isTodo = selectedParagraphsAreTodo()
        let todoTitle = isTodo ? language.text(.cancelTodo) : language.text(.makeTodo)
        let todoItem = NSMenuItem(
            title: todoTitle,
            action: isTodo ? #selector(removeTodoFormat) : #selector(convertSelectionToTodo),
            keyEquivalent: ""
        )
        todoItem.target = self
        menu.addItem(todoItem)

        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if toggleTodoCircleIfNeeded(event: event) {
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        if todoMarkerRect(at: convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
        super.mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleCommandShortcut(event) {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCommandShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return false
        }

        if let shortcutAction = AppShortcutAction.matching(event),
           let shortcut = shortcutAction.pinStickyShortcutKey {
            switch shortcut {
            case .closeNote:
                return (window as? StickerNoteWindow)?.noteShortcutHandler?(.closeNote) == true
            default:
                break
            }
        }

        switch event.pinStickyShortcutKey {
        case .undo:
            undoManager?.undo()
            return true
        case .redo:
            undoManager?.redo()
            return true
        case .copy:
            copy(nil)
            return true
        case .paste:
            paste(nil)
            return true
        case .cut:
            cut(nil)
            return true
        case .selectAll:
            selectAll(nil)
            return true
        default:
            break
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }

        switch event.keyCode {
        case 11:
            owner?.toggleBold()
            return true
        case 32:
            owner?.toggleUnderline()
            return true
        default:
            return false
        }
    }

    @objc private func convertSelectionToTodo() {
        owner?.convertSelectionToTodo()
    }

    @objc private func removeTodoFormat() {
        owner?.removeTodoFormatFromSelection()
    }

    @objc private func applyColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        owner?.applyTextColor(color)
    }

    @objc private func toggleUnderline() {
        owner?.toggleUnderline()
    }

    @objc private func toggleBold() {
        owner?.toggleBold()
    }

    @objc private func toggleStrikethrough() {
        owner?.toggleStrikethrough()
    }

    @objc private func applyLineSpacing(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let option = LineSpacingOption(rawValue: rawValue) else {
            return
        }
        owner?.applyLineSpacing(option)
    }

    private func actionItem(title: String, selector: Selector, systemImage: String, isChecked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: isChecked ? "\(title)  ✓" : title, action: selector, keyEquivalent: "")
        item.target = self
        item.state = .off
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }

    private func normalizedPlainText(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.newlines).joined(separator: "\n")
    }

    private func defaultTypingAttributes(for owner: NoteRichTextEditor.Coordinator) -> [NSAttributedString.Key: Any] {
        let note = owner.store.note
        let theme = BuiltInThemes.theme(id: note.themeID)
        return [
            .font: NSFont.systemFont(ofSize: note.fontSize, weight: .medium),
            .foregroundColor: NSColor(hex: theme.foreground),
            .paragraphStyle: NSParagraphStyle.pinStickyDefault(fontSize: note.fontSize),
            .kern: 0
        ]
    }

    private func toggleTodoCircleIfNeeded(event: NSEvent) -> Bool {
        let eventPoint = convert(event.locationInWindow, from: nil)
        guard let marker = todoMarkerRect(at: eventPoint) else { return false }
        textStorage?.replaceCharacters(in: NSRange(location: marker.location, length: 1), with: marker.value == "○" ? "●" : "○")
        owner?.store.updateContent(string)
        return true
    }

    private func todoMarkerRect(at eventPoint: CGPoint) -> (rect: CGRect, location: Int, value: String)? {
        guard let textContainer,
              let layoutManager,
              let storage = textStorage,
              storage.length > 0 else {
            return nil
        }

        let containerOrigin = textContainerOrigin
        let point = CGPoint(x: eventPoint.x - containerOrigin.x, y: eventPoint.y - containerOrigin.y)
        guard point.x >= -4 else { return nil }

        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let characterIndex = min(layoutManager.characterIndexForGlyph(at: glyphIndex), storage.length - 1)
        let fullText = storage.string as NSString
        let paragraphRange = fullText.paragraphRange(for: NSRange(location: characterIndex, length: 0))
        let paragraph = fullText.substring(with: paragraphRange) as NSString
        let leadingWhitespaceCount = paragraph.rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
        guard leadingWhitespaceCount != NSNotFound else { return nil }

        let markerLocation = paragraphRange.location + leadingWhitespaceCount
        guard markerLocation < storage.length else { return nil }
        let marker = fullText.substring(with: NSRange(location: markerLocation, length: 1))
        guard marker == "○" || marker == "●" else { return nil }

        let markerGlyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: markerLocation, length: 1),
            actualCharacterRange: nil
        )
        let markerRect = layoutManager.boundingRect(
            forGlyphRange: markerGlyphRange,
            in: textContainer
        ).offsetBy(dx: containerOrigin.x, dy: containerOrigin.y).insetBy(dx: -8, dy: -6)

        guard markerRect.contains(eventPoint) else { return nil }
        return (markerRect, markerLocation, marker)
    }

    private func selectedParagraphsAreTodo() -> Bool {
        let selectedRange = selectedRange()
        let targetRange = selectedRange.length > 0 ? selectedRange : rangeForUserParagraphAttributeChange
        guard targetRange.location != NSNotFound, !string.isEmpty else { return false }

        let nsString = string as NSString
        let paragraphRange = nsString.paragraphRange(for: targetRange)
        let text = nsString.substring(with: paragraphRange)
        let lines = text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("○ ") || trimmed.hasPrefix("● ")
        }
    }
}

final class PinStickyTextEditorContainer: NSView {
    weak var textView: NSTextView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let textView {
                addSubview(textView)
                configureTextLayout()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func layout() {
        super.layout()
        configureTextLayout()
    }

    func configureTextLayout() {
        guard let textView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let size = NSSize(width: max(bounds.width, 1), height: max(bounds.height, 1))

        textView.textContainerInset = NSSize(width: 0, height: 0)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: size)

        textView.minSize = size
        textView.maxSize = size
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.needsDisplay = true
        needsDisplay = true
        layoutManager.ensureLayout(for: textContainer)
    }
}

private extension NSTextView {
    var isFirstResponderInWindow: Bool {
        window?.firstResponder === self
    }

    var currentCharacterAttributeState: CharacterAttributeState {
        guard let storage = textStorage else { return CharacterAttributeState() }
        if storage.length == 0 {
            return CharacterAttributeState(
                bold: (typingAttributes[.font] as? NSFont)?.pinStickyIsBold == true,
                underline: (typingAttributes[.underlineStyle] as? Int ?? 0) != 0,
                strikethrough: (typingAttributes[.strikethroughStyle] as? Int ?? 0) != 0
            )
        }

        let selected = selectedRange()
        let range: NSRange
        if selected.length > 0 {
            range = selected
        } else {
            let location = min(max(selected.location - 1, 0), storage.length - 1)
            range = NSRange(location: location, length: 1)
        }

        return CharacterAttributeState(
            bold: storage.pinStickyAllCharacters(in: range) { attributes in
                (attributes[.font] as? NSFont)?.pinStickyIsBold == true
            },
            underline: storage.pinStickyAllCharacters(in: range) { attributes in
                (attributes[.underlineStyle] as? Int ?? 0) != 0
            },
            strikethrough: storage.pinStickyAllCharacters(in: range) { attributes in
                (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            }
        )
    }
}

private extension NSTextStorage {
    func pinStickyAllCharacters(in range: NSRange, satisfy predicate: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        let clampedRange = NSRange(
            location: min(max(range.location, 0), length),
            length: min(max(range.length, 0), max(0, length - min(max(range.location, 0), length)))
        )
        guard clampedRange.length > 0 else { return false }

        var allMatch = true
        enumerateAttributes(in: clampedRange) { attributes, _, stop in
            if !predicate(attributes) {
                allMatch = false
                stop.pointee = true
            }
        }
        return allMatch
    }
}

private extension NSFont {
    var pinStickyIsBold: Bool {
        NSFontManager.shared.traits(of: self).contains(.boldFontMask)
    }
}

enum LineSpacingOption: String, CaseIterable {
    case large
    case normal
    case tight

    func value(fontSize: Double) -> CGFloat {
        switch self {
        case .large: CGFloat(fontSize * 0.42)
        case .normal: CGFloat(fontSize * 0.20)
        case .tight: CGFloat(fontSize * 0.06)
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .large: language.text(.lineSpacingLarge)
        case .normal: language.text(.lineSpacingNormal)
        case .tight: language.text(.lineSpacingTight)
        }
    }
}

enum PinStickyShortcutKey {
    case undo
    case redo
    case copy
    case paste
    case cut
    case selectAll
    case newNote
    case noteList
    case showAll
    case selectNote
    case collapseExpand
    case nextTheme
    case reset
    case closeNote
    case settings
    case quit
}

extension AppShortcutAction {
    var pinStickyShortcutKey: PinStickyShortcutKey? {
        switch self {
        case .newNote: .newNote
        case .noteList: .noteList
        case .showAll: .showAll
        case .selectNote: .selectNote
        case .collapseExpand: .collapseExpand
        case .nextTheme: .nextTheme
        case .closeNote: .closeNote
        case .settings: .settings
        case .quit: .quit
        }
    }
}

extension NSEvent {
    var pinStickyShortcutKey: PinStickyShortcutKey? {
        switch keyCode {
        case 6:
            modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) ? .redo : .undo
        case 8: .copy
        case 9: .paste
        case 7: .cut
        case 0: .selectAll
        case 45: .newNote
        case 37: .noteList
        case 1: .showAll
        case 2: .collapseExpand
        case 17: .nextTheme
        case 15: .reset
        case 13: .closeNote
        case 43: .settings
        case 12: .quit
        default: nil
        }
    }
}

private struct TextColorOption {
    let englishTitle: String
    let koreanTitle: String
    let color: NSColor

    static let all: [TextColorOption] = [
        TextColorOption(englishTitle: "Ink", koreanTitle: "잉크", color: NSColor(hex: 0x202020)),
        TextColorOption(englishTitle: "White", koreanTitle: "화이트", color: .white),
        TextColorOption(englishTitle: "Blue", koreanTitle: "블루", color: NSColor(hex: 0x1558DD)),
        TextColorOption(englishTitle: "Pink", koreanTitle: "핑크", color: NSColor(hex: 0xFF3E9E)),
        TextColorOption(englishTitle: "Yellow", koreanTitle: "옐로우", color: NSColor(hex: 0xFFF22E)),
        TextColorOption(englishTitle: "Green", koreanTitle: "그린", color: NSColor(hex: 0x09B875))
    ]

    func title(language: AppLanguage) -> String {
        language == .korean ? koreanTitle : englishTitle
    }

    var swatchImage: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 10, height: 10)).fill()
        NSColor.black.withAlphaComponent(0.16).setStroke()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 10, height: 10)).stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private extension StickerNote {
    func makeAttributedString(theme: NoteTheme) -> NSAttributedString {
        return NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor(hex: theme.foreground),
                .paragraphStyle: NSParagraphStyle.pinStickyDefault(fontSize: fontSize)
            ]
        )
    }
}

private extension NSParagraphStyle {
    static func pinStickyDefault(fontSize: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(fontSize * 0.20)
        return style
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex & 0xFF0000) >> 16) / 255
        let green = CGFloat((hex & 0x00FF00) >> 8) / 255
        let blue = CGFloat(hex & 0x0000FF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
