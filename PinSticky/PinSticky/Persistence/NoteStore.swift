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

    static func makeNew(offset: Int) -> NoteStore {
        makeNew(offset: offset, inheriting: nil)
    }

    static func makeNew(offset: Int, inheriting source: StickerNote?, themeID selectedThemeID: String? = nil) -> NoteStore {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = CGPoint(
            x: visible.minX + 140 + CGFloat(offset % 8) * 28,
            y: visible.maxY - 320 - CGFloat(offset % 8) * 28
        )
        var note = StickerNote.fresh(origin: origin)
        if let source {
            note.themeID = source.themeID
            note.displayMode = source.displayMode
            note.attachedAppName = source.attachedAppName
            note.attachedBundleIdentifier = source.attachedBundleIdentifier
        } else {
            let themeID = selectedThemeID ?? savedDefaultThemeID()
            note.themeID = BuiltInThemes.theme(id: themeID).id
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
        guard note.content != content else { return }
        mutateNote { note in
            note.content = content
        }
    }

    func updateAttributedContent(_ attributedString: NSAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let data = try? attributedString.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let plainText = attributedString.string

        guard note.content != plainText || note.attributedContentData != data else { return }
        mutateNote { note in
            note.content = plainText
            note.attributedContentData = data
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
