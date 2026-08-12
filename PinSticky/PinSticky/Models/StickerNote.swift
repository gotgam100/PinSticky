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

    static func fresh(origin: CGPoint) -> StickerNote {
        StickerNote(
            id: UUID(),
            content: "새 메모",
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
        case (.korean, .defaultBackground): "기본 배경색"
        case (.english, .defaultBackground): "Default Background"
        case (.korean, .defaultTextColor): "기본 글자색"
        case (.english, .defaultTextColor): "Default Text Color"
        case (.korean, .systemTextColor): "배경색에 맞춤"
        case (.english, .systemTextColor): "Match Background"
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
        }
    }
}

enum AppText {
    case newNote
    case showNote
    case collapseExpand
    case nextTheme
    case quit
    case closeNote
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
