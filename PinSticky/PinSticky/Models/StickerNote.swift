import AppKit
import Carbon.HIToolbox
import Foundation

struct StickerNote: Codable, Equatable, Identifiable {
    var id: UUID
    var content: String
    var attributedContentData: Data?
    var themeID: String
    var fontSize: Double
    var isCollapsed: Bool
    var displayMode: NoteDisplayMode
    var attachedAppName: String?
    var attachedBundleIdentifier: String?
    var expandedFrame: CodableRect
    var collapsedOrigin: CodablePoint
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case attributedContentData
        case themeID
        case fontSize
        case isCollapsed
        case displayMode
        case attachedAppName
        case attachedBundleIdentifier
        case expandedFrame
        case collapsedOrigin
        case updatedAt
    }

    init(
        id: UUID,
        content: String,
        attributedContentData: Data?,
        themeID: String,
        fontSize: Double,
        isCollapsed: Bool,
        displayMode: NoteDisplayMode,
        attachedAppName: String?,
        attachedBundleIdentifier: String?,
        expandedFrame: CodableRect,
        collapsedOrigin: CodablePoint,
        updatedAt: Date
    ) {
        self.id = id
        self.content = content
        self.attributedContentData = attributedContentData
        self.themeID = themeID
        self.fontSize = fontSize
        self.isCollapsed = isCollapsed
        self.displayMode = displayMode
        self.attachedAppName = attachedAppName
        self.attachedBundleIdentifier = attachedBundleIdentifier
        self.expandedFrame = expandedFrame
        self.collapsedOrigin = collapsedOrigin
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        attributedContentData = try container.decodeIfPresent(Data.self, forKey: .attributedContentData)
        themeID = try container.decode(String.self, forKey: .themeID)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        displayMode = try container.decodeIfPresent(NoteDisplayMode.self, forKey: .displayMode) ?? .always
        attachedAppName = try container.decodeIfPresent(String.self, forKey: .attachedAppName)
        attachedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .attachedBundleIdentifier)
        expandedFrame = try container.decode(CodableRect.self, forKey: .expandedFrame)
        collapsedOrigin = try container.decode(CodablePoint.self, forKey: .collapsedOrigin)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    static let fallback = StickerNote(
        id: UUID(),
        content: "오늘 붙여둘 메모\n\n- 바로 적고\n- 창을 옮기고\n- 다시 실행해 보세요.",
        attributedContentData: nil,
        themeID: BuiltInThemes.defaultTheme.id,
        fontSize: 18,
        isCollapsed: false,
        displayMode: .always,
        attachedAppName: nil,
        attachedBundleIdentifier: nil,
        expandedFrame: CodableRect(x: 160, y: 420, width: 320, height: 260),
        collapsedOrigin: CodablePoint(x: 220, y: 520),
        updatedAt: Date()
    )

    static func fresh(origin: CGPoint, language: AppLanguage = .korean) -> StickerNote {
        StickerNote(
            id: UUID(),
            content: language.text(.newNote),
            attributedContentData: nil,
            themeID: BuiltInThemes.defaultTheme.id,
            fontSize: 18,
            isCollapsed: false,
            displayMode: .always,
            attachedAppName: nil,
            attachedBundleIdentifier: nil,
            expandedFrame: CodableRect(x: origin.x, y: origin.y, width: 320, height: 260),
            collapsedOrigin: CodablePoint(x: origin.x + 120, y: origin.y + 100),
            updatedAt: Date()
        )
    }
}

struct DeletedStickerNote: Codable, Equatable, Identifiable {
    var id: UUID { note.id }
    var note: StickerNote
    var deletedAt: Date

    var previewTitle: String {
        let firstLine = note.content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine, !firstLine.isEmpty else {
            return "Untitled"
        }
        return firstLine
    }
}

struct AppShortcut: Codable, Equatable {
    var keyCode: UInt32
    var characters: String
    var usesCommand: Bool
    var usesOption: Bool
    var usesControl: Bool
    var usesShift: Bool

    var isValid: Bool {
        !characters.isEmpty && (usesCommand || usesOption || usesControl || usesShift)
    }

    var keyEquivalent: String {
        characters.lowercased()
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if usesCommand { mask.insert(.command) }
        if usesOption { mask.insert(.option) }
        if usesControl { mask.insert(.control) }
        if usesShift { mask.insert(.shift) }
        return mask
    }

    var carbonModifierMask: UInt32 {
        var mask: UInt32 = 0
        if usesCommand { mask |= UInt32(cmdKey) }
        if usesOption { mask |= UInt32(optionKey) }
        if usesControl { mask |= UInt32(controlKey) }
        if usesShift { mask |= UInt32(shiftKey) }
        return mask
    }

    var displayText: String {
        var parts: [String] = []
        if usesControl { parts.append("⌃") }
        if usesOption { parts.append("⌥") }
        if usesShift { parts.append("⇧") }
        if usesCommand { parts.append("⌘") }
        parts.append(characters.uppercased())
        return parts.joined()
    }

    func matches(_ event: NSEvent) -> Bool {
        guard isValid, event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var expected: NSEvent.ModifierFlags = []
        if usesCommand { expected.insert(.command) }
        if usesOption { expected.insert(.option) }
        if usesControl { expected.insert(.control) }
        if usesShift { expected.insert(.shift) }
        return flags == expected
    }

    static func shortcut(forInput input: String, basedOn shortcut: AppShortcut) -> AppShortcut? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 1,
              let character = normalized.first,
              let keyCode = keyCode(for: character) else {
            return nil
        }
        var next = shortcut
        next.characters = String(character)
        next.keyCode = keyCode
        return next
    }

    static func keyCode(for character: Character) -> UInt32? {
        switch character {
        case "A": UInt32(kVK_ANSI_A)
        case "B": UInt32(kVK_ANSI_B)
        case "C": UInt32(kVK_ANSI_C)
        case "D": UInt32(kVK_ANSI_D)
        case "E": UInt32(kVK_ANSI_E)
        case "F": UInt32(kVK_ANSI_F)
        case "G": UInt32(kVK_ANSI_G)
        case "H": UInt32(kVK_ANSI_H)
        case "I": UInt32(kVK_ANSI_I)
        case "J": UInt32(kVK_ANSI_J)
        case "K": UInt32(kVK_ANSI_K)
        case "L": UInt32(kVK_ANSI_L)
        case "M": UInt32(kVK_ANSI_M)
        case "N": UInt32(kVK_ANSI_N)
        case "O": UInt32(kVK_ANSI_O)
        case "P": UInt32(kVK_ANSI_P)
        case "Q": UInt32(kVK_ANSI_Q)
        case "R": UInt32(kVK_ANSI_R)
        case "S": UInt32(kVK_ANSI_S)
        case "T": UInt32(kVK_ANSI_T)
        case "U": UInt32(kVK_ANSI_U)
        case "V": UInt32(kVK_ANSI_V)
        case "W": UInt32(kVK_ANSI_W)
        case "X": UInt32(kVK_ANSI_X)
        case "Y": UInt32(kVK_ANSI_Y)
        case "Z": UInt32(kVK_ANSI_Z)
        case "0": UInt32(kVK_ANSI_0)
        case "1": UInt32(kVK_ANSI_1)
        case "2": UInt32(kVK_ANSI_2)
        case "3": UInt32(kVK_ANSI_3)
        case "4": UInt32(kVK_ANSI_4)
        case "5": UInt32(kVK_ANSI_5)
        case "6": UInt32(kVK_ANSI_6)
        case "7": UInt32(kVK_ANSI_7)
        case "8": UInt32(kVK_ANSI_8)
        case "9": UInt32(kVK_ANSI_9)
        case ",": UInt32(kVK_ANSI_Comma)
        case ".": UInt32(kVK_ANSI_Period)
        case "/": UInt32(kVK_ANSI_Slash)
        case ";": UInt32(kVK_ANSI_Semicolon)
        case "'": UInt32(kVK_ANSI_Quote)
        case "[": UInt32(kVK_ANSI_LeftBracket)
        case "]": UInt32(kVK_ANSI_RightBracket)
        case "\\": UInt32(kVK_ANSI_Backslash)
        case "-": UInt32(kVK_ANSI_Minus)
        case "=": UInt32(kVK_ANSI_Equal)
        default: nil
        }
    }
}

enum AppShortcutAction: String, CaseIterable, Identifiable {
    case newNote
    case noteList
    case showAll
    case collapseExpand
    case nextTheme
    case closeNote
    case settings
    case quit

    var id: String { rawValue }

    static let configurableCases: [AppShortcutAction] = [
        .newNote,
        .noteList,
        .showAll,
        .collapseExpand,
        .nextTheme,
        .closeNote,
        .settings,
        .quit
    ]

    var defaultShortcut: AppShortcut {
        switch self {
        case .newNote:
            AppShortcut(keyCode: UInt32(kVK_ANSI_N), characters: "N", usesCommand: true, usesOption: true, usesControl: false, usesShift: false)
        case .noteList:
            AppShortcut(keyCode: UInt32(kVK_ANSI_L), characters: "L", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .showAll:
            AppShortcut(keyCode: UInt32(kVK_ANSI_S), characters: "S", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .collapseExpand:
            AppShortcut(keyCode: UInt32(kVK_ANSI_D), characters: "D", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .nextTheme:
            AppShortcut(keyCode: UInt32(kVK_ANSI_T), characters: "T", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .closeNote:
            AppShortcut(keyCode: UInt32(kVK_ANSI_W), characters: "W", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .settings:
            AppShortcut(keyCode: UInt32(kVK_ANSI_Comma), characters: ",", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        case .quit:
            AppShortcut(keyCode: UInt32(kVK_ANSI_Q), characters: "Q", usesCommand: true, usesOption: false, usesControl: false, usesShift: false)
        }
    }

    var appText: AppText {
        switch self {
        case .newNote: .newNote
        case .noteList: .noteList
        case .showAll: .showNote
        case .collapseExpand: .collapseExpand
        case .nextTheme: .nextTheme
        case .closeNote: .closeNote
        case .settings: .settings
        case .quit: .quit
        }
    }

    func title(language: AppLanguage) -> String {
        language.text(appText)
    }

    func savedShortcut() -> AppShortcut {
        AppShortcutStore.savedShortcut(for: self)
    }

    static func matching(_ event: NSEvent) -> AppShortcutAction? {
        configurableCases.first { $0.savedShortcut().matches(event) }
    }
}

enum AppShortcutStore {
    private static let legacyNewNoteKeyCode = "globalNewNoteShortcutKeyCode"
    private static let legacyNewNoteCharacters = "globalNewNoteShortcutCharacters"
    private static let legacyNewNoteCommand = "globalNewNoteShortcutCommand"
    private static let legacyNewNoteOption = "globalNewNoteShortcutOption"
    private static let legacyNewNoteControl = "globalNewNoteShortcutControl"
    private static let legacyNewNoteShift = "globalNewNoteShortcutShift"

    static func savedShortcut(for action: AppShortcutAction) -> AppShortcut {
        let prefix = defaultsPrefix(for: action)
        guard UserDefaults.standard.object(forKey: "\(prefix).keyCode") != nil else {
            if action == .newNote,
               UserDefaults.standard.object(forKey: legacyNewNoteKeyCode) != nil {
                return AppShortcut(
                    keyCode: UInt32(UserDefaults.standard.integer(forKey: legacyNewNoteKeyCode)),
                    characters: UserDefaults.standard.string(forKey: legacyNewNoteCharacters) ?? action.defaultShortcut.characters,
                    usesCommand: UserDefaults.standard.bool(forKey: legacyNewNoteCommand),
                    usesOption: UserDefaults.standard.bool(forKey: legacyNewNoteOption),
                    usesControl: UserDefaults.standard.bool(forKey: legacyNewNoteControl),
                    usesShift: UserDefaults.standard.bool(forKey: legacyNewNoteShift)
                )
            }
            return action.defaultShortcut
        }

        return AppShortcut(
            keyCode: UInt32(UserDefaults.standard.integer(forKey: "\(prefix).keyCode")),
            characters: UserDefaults.standard.string(forKey: "\(prefix).characters") ?? action.defaultShortcut.characters,
            usesCommand: UserDefaults.standard.bool(forKey: "\(prefix).command"),
            usesOption: UserDefaults.standard.bool(forKey: "\(prefix).option"),
            usesControl: UserDefaults.standard.bool(forKey: "\(prefix).control"),
            usesShift: UserDefaults.standard.bool(forKey: "\(prefix).shift")
        )
    }

    static func save(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        let prefix = defaultsPrefix(for: action)
        UserDefaults.standard.set(Int(shortcut.keyCode), forKey: "\(prefix).keyCode")
        UserDefaults.standard.set(shortcut.characters.uppercased(), forKey: "\(prefix).characters")
        UserDefaults.standard.set(shortcut.usesCommand, forKey: "\(prefix).command")
        UserDefaults.standard.set(shortcut.usesOption, forKey: "\(prefix).option")
        UserDefaults.standard.set(shortcut.usesControl, forKey: "\(prefix).control")
        UserDefaults.standard.set(shortcut.usesShift, forKey: "\(prefix).shift")
    }

    static func reset(_ action: AppShortcutAction) {
        save(action.defaultShortcut, for: action)
    }

    private static func defaultsPrefix(for action: AppShortcutAction) -> String {
        "appShortcut.\(action.rawValue)"
    }
}

enum GlobalNewNoteShortcut {
    static func saved() -> AppShortcut {
        AppShortcutStore.savedShortcut(for: .newNote)
    }

    static func save(_ shortcut: AppShortcut) {
        AppShortcutStore.save(shortcut, for: .newNote)
    }
}

enum NoteDisplayMode: String, Codable, Equatable {
    case always
    case whenAppIsActive
}

enum AppLanguage: String, CaseIterable, Equatable {
    case korean
    case english

    var title: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    func title(displayedIn language: AppLanguage) -> String {
        switch (self, language) {
        case (.korean, .korean): "한국어"
        case (.korean, .english): "Korean"
        case (.english, _): "English"
        }
    }

    func text(_ key: AppText) -> String {
        switch (self, key) {
        case (.korean, .showNote): "모든 메모 보기"
        case (.english, .showNote): "Show All Notes"
        case (.korean, .noteList): "메모 관리 및 검색"
        case (.english, .noteList): "Manage and Search Notes"
        case (.korean, .searchNotes): "메모 검색"
        case (.english, .searchNotes): "Search notes"
        case (.korean, .noSearchResults): "검색 결과가 없습니다."
        case (.english, .noSearchResults): "No matching notes."
        case (.korean, .untitledNote): "제목 없는 메모"
        case (.english, .untitledNote): "Untitled Note"
        case (.korean, .noteModeShort): "메모"
        case (.english, .noteModeShort): "Note"
        case (.korean, .dotModeShort): "작은 원"
        case (.english, .dotModeShort): "Dot"
        case (.korean, .selectAll): "전체 선택"
        case (.english, .selectAll): "Select All"
        case (.korean, .deselectAll): "선택 해제"
        case (.english, .deselectAll): "Deselect"
        case (.korean, .selectedNotesPinMenu): "선택한 메모 종속"
        case (.english, .selectedNotesPinMenu): "Pin Selected Notes"
        case (.korean, .pinningStatus): "종속 상태"
        case (.english, .pinningStatus): "Pinning Status"
        case (.korean, .newNote): "새 메모"
        case (.english, .newNote): "New Note"
        case (.korean, .collapseExpand): "작은 원 / 펼치기"
        case (.english, .collapseExpand): "Collapse / Expand"
        case (.korean, .nextTheme): "다음 테마"
        case (.english, .nextTheme): "Next Theme"
        case (.korean, .quit): "PinSticky 종료"
        case (.english, .quit): "Quit PinSticky"
        case (.korean, .closeNote): "메모 닫기"
        case (.english, .closeNote): "Close Note"
        case (.korean, .closeAllNotes): "모든 메모 닫기"
        case (.english, .closeAllNotes): "Close All Notes"
        case (.korean, .closeAllNotesConfirmation): "모든 창을 닫으시겠습니까?"
        case (.english, .closeAllNotesConfirmation): "Close all note windows?"
        case (.korean, .allNotesPinMenu): "모든 메모 종속"
        case (.english, .allNotesPinMenu): "All Notes App Pinning"
        case (.korean, .clearAllAttachments): "모든 메모 종속 제거"
        case (.english, .clearAllAttachments): "Clear All App Attachments"
        case (.korean, .clearAllAttachmentsConfirmation): "모든 메모의 종속을 제거하시겠습니까?"
        case (.english, .clearAllAttachmentsConfirmation): "Clear app attachments from all notes?"
        case (.korean, .yes): "네"
        case (.english, .yes): "Yes"
        case (.korean, .no): "아니요"
        case (.english, .no): "No"
        case (.korean, .language): "언어"
        case (.english, .language): "Language"
        case (.korean, .pinMenu): "앱 종속"
        case (.english, .pinMenu): "App Pinning"
        case (.korean, .currentMode): "현재 상태"
        case (.english, .currentMode): "Current Mode"
        case (.korean, .alwaysVisible): "항상 표시"
        case (.english, .alwaysVisible): "Always Visible"
        case (.korean, .attachedTo): "연결된 앱"
        case (.english, .attachedTo): "Attached App"
        case (.korean, .attachToFrontmost): "현재 활성 앱에 붙이기"
        case (.english, .attachToFrontmost): "Attach to Frontmost App"
        case (.korean, .clearAttachment): "앱 종속 해제"
        case (.english, .clearAttachment): "Clear App Attachment"
        case (.korean, .notAttached): "앱에 종속되지 않음"
        case (.english, .notAttached): "Not Attached"
        case (.korean, .settingsSummary): "하나의 메모를 Mac 작업 공간 위에 띄우고, 내용과 창 위치를 재실행 후에도 복원합니다."
        case (.english, .settingsSummary): "Keeps one note floating above your Mac workspace, then restores its content and frame after relaunch."
        case (.korean, .floatingPanel): "항상 위에 있는 AppKit 패널"
        case (.english, .floatingPanel): "Always-on-top AppKit panel"
        case (.korean, .autosaved): "편집 내용과 위치 자동 저장"
        case (.english, .autosaved): "Auto-saved editor content and placement"
        case (.korean, .dotMode): "작은 원 접기 모드"
        case (.english, .dotMode): "Dot collapse mode"
        case (.korean, .palette): "샘플 이미지 기반 컬러 팔레트"
        case (.english, .palette): "Color palette inspired by the sample image"
        case (.korean, .makeTodo): "투두 형식으로 변경"
        case (.english, .makeTodo): "Convert to Todo"
        case (.korean, .textColor): "글씨 색상"
        case (.english, .textColor): "Text Color"
        case (.korean, .about): "PinSticky 정보"
        case (.english, .about): "About PinSticky"
        case (.korean, .settings): "설정"
        case (.english, .settings): "Settings"
        case (.korean, .defaultNewNote): "새 메모 기본값"
        case (.english, .defaultNewNote): "New Note Defaults"
        case (.korean, .defaultBackground): "배경색"
        case (.english, .defaultBackground): "Background"
        case (.korean, .defaultTextColor): "글자색"
        case (.english, .defaultTextColor): "Text Color"
        case (.korean, .systemTextColor): "배경색에 맞춤"
        case (.english, .systemTextColor): "Match Background"
        case (.korean, .launchAtLogin): "컴퓨터 로그인 시 자동실행"
        case (.english, .launchAtLogin): "Open at Login"
        case (.korean, .shortcutSettings): "단축키 설정"
        case (.english, .shortcutSettings): "Shortcut Settings"
        case (.korean, .newNoteShortcut): "새 메모"
        case (.english, .newNoteShortcut): "New Note"
        case (.korean, .shortcutKey): "키"
        case (.english, .shortcutKey): "Key"
        case (.korean, .termsAndPolicies): "이용약관 및 정책"
        case (.english, .termsAndPolicies): "Terms and Policies"
        case (.korean, .developerApps): "개발자의 다른 앱"
        case (.english, .developerApps): "More Apps by Developer"
        case (.korean, .deleteNote): "메모 삭제"
        case (.english, .deleteNote): "Delete Note"
        case (.korean, .cancelTodo): "투두 형식 취소"
        case (.english, .cancelTodo): "Remove Todo Format"
        case (.korean, .characterAttributes): "글자 속성"
        case (.english, .characterAttributes): "Character Attributes"
        case (.korean, .underline): "밑줄"
        case (.english, .underline): "Underline"
        case (.korean, .italic): "기울이기"
        case (.english, .italic): "Italic"
        case (.korean, .strikethrough): "취소선"
        case (.english, .strikethrough): "Strikethrough"
        case (.korean, .paragraphAttributes): "문단 속성"
        case (.english, .paragraphAttributes): "Paragraph Attributes"
        case (.korean, .lineSpacingLarge): "줄간격 크게"
        case (.english, .lineSpacingLarge): "Large Line Spacing"
        case (.korean, .lineSpacingNormal): "줄간격 보통"
        case (.english, .lineSpacingNormal): "Normal Line Spacing"
        case (.korean, .lineSpacingTight): "줄간격 좁게"
        case (.english, .lineSpacingTight): "Tight Line Spacing"
        case (.korean, .restoreDeletedNotes): "지운 메모 복구"
        case (.english, .restoreDeletedNotes): "Restore Deleted Notes"
        case (.korean, .noDeletedNotes): "복구할 지운 메모가 없습니다."
        case (.english, .noDeletedNotes): "No deleted notes to restore."
        case (.korean, .restore): "복구"
        case (.english, .restore): "Restore"
        case (.korean, .refresh): "새로고침"
        case (.english, .refresh): "Refresh"
        case (.korean, .resetShortcut): "기본값"
        case (.english, .resetShortcut): "Default"
        }
    }

    func shortcutConflictText(_ actionTitle: String) -> String {
        switch self {
        case .korean: "\(actionTitle)에 이미 배정되어 사용할 수 없습니다."
        case .english: "Already assigned to \(actionTitle)."
        }
    }
}

enum AppText {
    case newNote
    case showNote
    case noteList
    case searchNotes
    case noSearchResults
    case untitledNote
    case noteModeShort
    case dotModeShort
    case selectAll
    case deselectAll
    case selectedNotesPinMenu
    case pinningStatus
    case collapseExpand
    case nextTheme
    case quit
    case closeNote
    case closeAllNotes
    case closeAllNotesConfirmation
    case allNotesPinMenu
    case clearAllAttachments
    case clearAllAttachmentsConfirmation
    case yes
    case no
    case language
    case pinMenu
    case currentMode
    case alwaysVisible
    case attachedTo
    case attachToFrontmost
    case clearAttachment
    case notAttached
    case settingsSummary
    case floatingPanel
    case autosaved
    case dotMode
    case palette
    case makeTodo
    case textColor
    case about
    case settings
    case defaultNewNote
    case defaultBackground
    case defaultTextColor
    case systemTextColor
    case launchAtLogin
    case shortcutSettings
    case newNoteShortcut
    case shortcutKey
    case termsAndPolicies
    case developerApps
    case deleteNote
    case cancelTodo
    case characterAttributes
    case underline
    case italic
    case strikethrough
    case paragraphAttributes
    case lineSpacingLarge
    case lineSpacingNormal
    case lineSpacingTight
    case restoreDeletedNotes
    case noDeletedNotes
    case restore
    case refresh
    case resetShortcut
}

struct CodableRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CodablePoint: Codable, Equatable {
    var x: Double
    var y: Double
}
