import AppKit
import Combine
import Foundation

@MainActor
final class NoteStore: ObservableObject {
    @Published var note: StickerNote {
        didSet {
            scheduleSave()
        }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
        }
    }

    private static let languageDefaultsKey = "appLanguage"
    private static let hasLaunchedDefaultsKey = "hasLaunched"
    private static let defaultThemeDefaultsKey = "defaultNewNoteTheme"
    private static let defaultTextColorDefaultsKey = "defaultNewNoteTextColor"
    private static let defaultOpacityDefaultsKey = "defaultNewNoteOpacity"
    private static let defaultLiquidGlassDefaultsKey = "defaultNewNoteLiquidGlass"
    private static let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PinSticky", isDirectory: true)
    private static let deletedNotesLimit = 20
    private static let deletedNotesURL = supportURL.appendingPathComponent("deleted-notes.json")

    let fileURL: URL
    private var pendingSave: Task<Void, Never>?
    private var isDeleted = false

    init(note: StickerNote, fileURL: URL) {
        language = Self.savedLanguage()

        self.note = note
        self.fileURL = fileURL
        scheduleSave()
    }

    convenience init() {
        try? FileManager.default.createDirectory(at: Self.supportURL, withIntermediateDirectories: true)
        let legacyURL = Self.supportURL.appendingPathComponent("prototype-note.json")

        if let data = try? Data(contentsOf: legacyURL),
           let decoded = try? JSONDecoder.pinSticky.decode(StickerNote.self, from: data) {
            self.init(note: decoded, fileURL: Self.fileURL(for: decoded.id))
        } else {
            self.init(note: .fallback, fileURL: Self.fileURL(for: StickerNote.fallback.id))
        }
    }

    static func loadAll() -> [NoteStore] {
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let noteURLs = ((try? FileManager.default.contentsOfDirectory(
            at: supportURL,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "json" }
            .filter { $0.lastPathComponent.hasPrefix("note-") }

        let stores = noteURLs.compactMap { url -> NoteStore? in
            guard let data = try? Data(contentsOf: url),
                  let note = try? JSONDecoder.pinSticky.decode(StickerNote.self, from: data) else {
                return nil
            }
            return NoteStore(note: note, fileURL: fileURL(for: note.id))
        }

        if stores.isEmpty {
            guard !UserDefaults.standard.bool(forKey: hasLaunchedDefaultsKey) else {
                return []
            }

            UserDefaults.standard.set(true, forKey: hasLaunchedDefaultsKey)
            return [NoteStore()]
        }

        UserDefaults.standard.set(true, forKey: hasLaunchedDefaultsKey)
        return stores.sorted { $0.note.updatedAt < $1.note.updatedAt }
    }

    static func savedLanguage() -> AppLanguage {
        if let storedLanguage = UserDefaults.standard.string(forKey: languageDefaultsKey),
           let decodedLanguage = AppLanguage(rawValue: storedLanguage) {
            return decodedLanguage
        }
        return .korean
    }

    static func saveLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: languageDefaultsKey)
    }

    static func savedDefaultThemeID() -> String {
        let themeID = UserDefaults.standard.string(forKey: defaultThemeDefaultsKey) ?? BuiltInThemes.defaultTheme.id
        return BuiltInThemes.theme(id: themeID).id
    }

    static func saveDefaultThemeID(_ themeID: String) {
        UserDefaults.standard.set(BuiltInThemes.theme(id: themeID).id, forKey: defaultThemeDefaultsKey)
    }

    static func savedDefaultTextColor() -> UInt32? {
        guard UserDefaults.standard.object(forKey: defaultTextColorDefaultsKey) != nil else { return nil }
        return UInt32(UserDefaults.standard.integer(forKey: defaultTextColorDefaultsKey))
    }

    static func saveDefaultTextColor(_ color: UInt32?) {
        if let color {
            UserDefaults.standard.set(Int(color), forKey: defaultTextColorDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultTextColorDefaultsKey)
        }
    }

    static func savedDefaultOpacity() -> Double {
        guard UserDefaults.standard.object(forKey: defaultOpacityDefaultsKey) != nil else { return 1 }
        return StickerNote.clampedOpacity(UserDefaults.standard.double(forKey: defaultOpacityDefaultsKey))
    }

    static func saveDefaultOpacity(_ opacity: Double) {
        UserDefaults.standard.set(StickerNote.clampedOpacity(opacity), forKey: defaultOpacityDefaultsKey)
    }

    static func savedDefaultLiquidGlassEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: defaultLiquidGlassDefaultsKey)
    }

    static func saveDefaultLiquidGlassEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: defaultLiquidGlassDefaultsKey)
    }

    static func makeNew(offset: Int) -> NoteStore {
        makeNew(offset: offset, inheriting: nil)
    }

    static func makeNew(
        offset: Int,
        inheriting source: StickerNote?,
        themeID selectedThemeID: String? = nil,
        centeredAt centerPoint: CGPoint? = nil,
        near sourceFrame: CGRect? = nil
    ) -> NoteStore {
        let size = sourceFrame?.size ?? CGSize(width: 320, height: 260)
        let visible = bestVisibleFrame(for: centerPoint ?? sourceFrame?.center)
        let origin: CGPoint
        if let sourceFrame {
            origin = siblingOrigin(for: sourceFrame, size: size, visible: visible)
        } else if let centerPoint {
            origin = clampedOrigin(
                CGPoint(x: centerPoint.x - size.width / 2, y: centerPoint.y - size.height / 2),
                size: size,
                visible: visible
            )
        } else {
            origin = CGPoint(
                x: visible.minX + 140 + CGFloat(offset % 8) * 28,
                y: visible.maxY - size.height - 60 - CGFloat(offset % 8) * 28
            )
        }
        var note = StickerNote.fresh(origin: origin, language: savedLanguage())
        note.expandedFrame = CodableRect(
            x: Double(origin.x),
            y: Double(origin.y),
            width: Double(size.width),
            height: Double(size.height)
        )
        note.collapsedOrigin = CodablePoint(
            x: Double(origin.x + size.width / 2 - 14),
            y: Double(origin.y + size.height / 2 - 14)
        )
        if let source {
            note.themeID = source.themeID
            note.opacity = source.opacity
            note.usesLiquidGlass = source.usesLiquidGlass
            note.displayMode = source.displayMode
            note.attachedAppName = source.attachedAppName
            note.attachedBundleIdentifier = source.attachedBundleIdentifier
        } else {
            let themeID = selectedThemeID ?? savedDefaultThemeID()
            note.themeID = BuiltInThemes.theme(id: themeID).id
            note.opacity = savedDefaultOpacity()
            note.usesLiquidGlass = savedDefaultLiquidGlassEnabled()
            if let textColor = savedDefaultTextColor() {
                note.attributedContentData = attributedContentData(
                    content: note.content,
                    fontSize: note.fontSize,
                    textColor: textColor
                )
            }
        }
        return NoteStore(note: note, fileURL: fileURL(for: note.id))
    }

    private static func siblingOrigin(for sourceFrame: CGRect, size: CGSize, visible: CGRect) -> CGPoint {
        let gap: CGFloat = 24
        let candidates = [
            CGPoint(x: sourceFrame.maxX + gap, y: sourceFrame.minY),
            CGPoint(x: sourceFrame.minX - size.width - gap, y: sourceFrame.minY),
            CGPoint(x: sourceFrame.minX + gap, y: sourceFrame.minY - size.height - gap),
            CGPoint(x: sourceFrame.minX + gap, y: sourceFrame.maxY + gap),
            CGPoint(x: sourceFrame.minX + 36, y: sourceFrame.minY - 36)
        ]

        if let fittingOrigin = candidates.first(where: { origin in
            visible.contains(CGRect(origin: origin, size: size))
        }) {
            return fittingOrigin
        }

        return clampedOrigin(
            CGPoint(x: sourceFrame.minX + 36, y: sourceFrame.minY - 36),
            size: size,
            visible: visible
        )
    }

    private static func bestVisibleFrame(for point: CGPoint?) -> CGRect {
        if let point,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private static func clampedOrigin(_ origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }

    static func makeRestored(note: StickerNote) -> NoteStore {
        var restored = note
        restored.isCollapsed = false
        restored.updatedAt = Date()
        return NoteStore(note: restored, fileURL: fileURL(for: restored.id))
    }

    static func deletedNotes() -> [DeletedStickerNote] {
        guard let data = try? Data(contentsOf: deletedNotesURL),
              let decoded = try? JSONDecoder.pinSticky.decode([DeletedStickerNote].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.deletedAt > $1.deletedAt }
    }

    static func archiveDeletedNote(_ note: StickerNote) {
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        var deletedNotes = deletedNotes().filter { $0.note.id != note.id }
        deletedNotes.insert(DeletedStickerNote(note: note, deletedAt: Date()), at: 0)
        deletedNotes = Array(deletedNotes.prefix(deletedNotesLimit))
        saveDeletedNotes(deletedNotes)
    }

    static func restoreDeletedNote(id: UUID) -> StickerNote? {
        var deletedNotes = deletedNotes()
        guard let index = deletedNotes.firstIndex(where: { $0.note.id == id }) else {
            return nil
        }
        let note = deletedNotes.remove(at: index).note
        saveDeletedNotes(deletedNotes)
        return note
    }

    private static func saveDeletedNotes(_ deletedNotes: [DeletedStickerNote]) {
        guard let data = try? JSONEncoder.pinSticky.encode(deletedNotes) else { return }
        try? data.write(to: deletedNotesURL, options: .atomic)
    }

    private static func attributedContentData(content: String, fontSize: Double, textColor: UInt32) -> Data? {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(fontSize * 0.20)
        let attributed = NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor(hex: textColor),
                .paragraphStyle: paragraphStyle
            ]
        )
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func recoloredAttributedContentData(for note: StickerNote, textColor: UInt32) -> Data? {
        let attributed: NSMutableAttributedString
        if let data = note.attributedContentData,
           let decoded = try? NSMutableAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            attributed = decoded
        } else {
            attributed = NSMutableAttributedString(string: note.content)
        }

        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return nil }
        attributed.addAttribute(.foregroundColor, value: NSColor(hex: textColor), range: fullRange)
        return try? attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func fileURL(for id: UUID) -> URL {
        supportURL.appendingPathComponent("note-\(id.uuidString).json")
    }

    func updateContent(_ content: String) {
        guard note.content != content || note.attributedContentData != nil else { return }
        mutateNote { note in
            note.content = content
            note.attributedContentData = nil
        }
    }

    func updateAttributedContent(_ attributedString: NSAttributedString) {
        let plainText = attributedString.string
        guard note.content != plainText || note.attributedContentData != nil else { return }
        mutateNote { note in
            note.content = plainText
            note.attributedContentData = nil
        }
    }

    func updateTheme(_ themeID: String) {
        guard note.themeID != themeID else { return }
        let theme = BuiltInThemes.theme(id: themeID)
        mutateNote { note in
            note.themeID = theme.id
            note.attributedContentData = Self.recoloredAttributedContentData(for: note, textColor: theme.foreground)
        }
    }

    func cycleTheme() {
        guard let index = BuiltInThemes.all.firstIndex(where: { $0.id == note.themeID }) else {
            updateTheme(BuiltInThemes.defaultTheme.id)
            return
        }
        let nextIndex = BuiltInThemes.all.index(after: index)
        updateTheme(BuiltInThemes.all[nextIndex == BuiltInThemes.all.endIndex ? BuiltInThemes.all.startIndex : nextIndex].id)
    }

    func updateFontSize(_ fontSize: Double) {
        let clampedFontSize = min(max(fontSize, 13), 32)
        guard note.fontSize != clampedFontSize else { return }
        mutateNote { note in
            note.fontSize = clampedFontSize
        }
    }

    func updateOpacity(_ opacity: Double) {
        let clampedOpacity = StickerNote.clampedOpacity(opacity)
        guard note.opacity != clampedOpacity else { return }
        mutateNote { note in
            note.opacity = clampedOpacity
        }
    }

    func updateLiquidGlassEnabled(_ isEnabled: Bool) {
        guard note.usesLiquidGlass != isEnabled else { return }
        mutateNote { note in
            note.usesLiquidGlass = isEnabled
        }
    }

    func updateExpandedFrame(_ frame: CGRect) {
        let nextFrame = CodableRect(frame)
        guard note.expandedFrame != nextFrame else { return }
        mutateNote { note in
            note.expandedFrame = nextFrame
        }
    }

    func updateCollapsedOrigin(_ origin: CGPoint) {
        let nextOrigin = CodablePoint(origin)
        guard note.collapsedOrigin != nextOrigin else { return }
        mutateNote { note in
            note.collapsedOrigin = nextOrigin
        }
    }

    func updateCollapsed(_ isCollapsed: Bool) {
        guard note.isCollapsed != isCollapsed else { return }
        mutateNote { note in
            note.isCollapsed = isCollapsed
        }
    }

    func updateLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.language != language else { return }
            self.language = language
        }
    }

    func setAlwaysVisible() {
        mutateNote { note in
            note.displayMode = .always
            note.attachedAppName = nil
            note.attachedBundleIdentifier = nil
        }
    }

    func attach(to application: RunningApplicationInfo?) {
        guard let application else {
            return
        }

        mutateNote { note in
            note.displayMode = .whenAppIsActive
            note.attachedAppName = application.name
            note.attachedBundleIdentifier = application.bundleIdentifier
        }
    }

    func flush() {
        guard !isDeleted else { return }
        pendingSave?.cancel()
        save()
    }

    func deleteFile() {
        isDeleted = true
        pendingSave?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func scheduleSave() {
        guard !isDeleted else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard !isDeleted else { return }
        guard let data = try? JSONEncoder.pinSticky.encode(note) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func mutateNote(_ mutation: (inout StickerNote) -> Void) {
        var nextNote = note
        mutation(&nextNote)
        nextNote.updatedAt = Date()
        note = nextNote
    }
}

extension NSAttributedString {
    func pinStickySanitized(fontSize: Double, textColor: UInt32) -> NSAttributedString {
        let sanitized = NSMutableAttributedString(attributedString: self)
        let fullRange = NSRange(location: 0, length: sanitized.length)
        guard fullRange.length > 0 else { return sanitized }

        let defaultColor = NSColor(hex: textColor)
        sanitized.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                sanitized.addAttribute(.font, value: font.pinStickyFontPreservingTraits(fontSize: fontSize), range: range)
            } else {
                sanitized.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: .medium), range: range)
            }

            if attributes[.foregroundColor] == nil {
                sanitized.addAttribute(.foregroundColor, value: defaultColor, range: range)
            }

            sanitized.addAttribute(.kern, value: 0, range: range)
            sanitized.removeAttribute(.backgroundColor, range: range)
            sanitized.removeAttribute(.baselineOffset, range: range)
            sanitized.removeAttribute(.superscript, range: range)
            sanitized.removeAttribute(.link, range: range)
            sanitized.removeAttribute(.attachment, range: range)
            sanitized.removeAttribute(.shadow, range: range)
            sanitized.removeAttribute(.obliqueness, range: range)
            sanitized.removeAttribute(.expansion, range: range)
            sanitized.removeAttribute(.writingDirection, range: range)
            sanitized.removeAttribute(.verticalGlyphForm, range: range)
        }

        let string = sanitized.string as NSString
        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            let existingStyle = sanitized.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            sanitized.addAttribute(
                .paragraphStyle,
                value: existingStyle.pinStickyNormalized(fontSize: fontSize),
                range: paragraphRange
            )
            location = NSMaxRange(paragraphRange)
        }

        return sanitized
    }
}

private extension NSFont {
    func pinStickyFontPreservingTraits(fontSize: Double) -> NSFont {
        let traits = NSFontManager.shared.traits(of: self)
        var font = NSFont.systemFont(ofSize: fontSize, weight: traits.contains(.boldFontMask) ? .bold : .medium)
        if traits.contains(.italicFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

private extension Optional where Wrapped == NSParagraphStyle {
    func pinStickyNormalized(fontSize: Double) -> NSParagraphStyle {
        let normalized = NSMutableParagraphStyle()
        normalized.alignment = self?.alignment ?? .natural
        normalized.baseWritingDirection = self?.baseWritingDirection ?? .natural
        let defaultLineSpacing = CGFloat(fontSize * 0.20)
        let existingLineSpacing = self?.lineSpacing ?? defaultLineSpacing
        normalized.lineSpacing = existingLineSpacing.isFinite
            ? min(max(existingLineSpacing, 0), CGFloat(fontSize * 0.55))
            : defaultLineSpacing
        normalized.paragraphSpacing = 0
        normalized.paragraphSpacingBefore = 0
        normalized.lineHeightMultiple = 0
        normalized.minimumLineHeight = 0
        normalized.maximumLineHeight = 0
        return normalized
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension JSONEncoder {
    static var pinSticky: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var pinSticky: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension CodableRect {
    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

extension CodablePoint {
    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
