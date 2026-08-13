import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("appLanguage") private var storedLanguage = AppLanguage.korean.rawValue
    @State private var selectedThemeID = NoteStore.savedDefaultThemeID()
    @State private var selectedTextColor = NoteStore.savedDefaultTextColor().map(Int.init) ?? -1
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onChange: (() -> Void)? = nil
    var openShortcutSettings: (() -> Void)? = nil

    private var language: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .korean
    }

    private let termsAndPoliciesURL = URL(string: "https://gotgam100.github.io/PinSticky/")!
    private let developerAppsURL = URL(string: "macappstore://itunes.apple.com/search?term=Seunghwa%20Baek&mt=12")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)

                    Text("Pin Sticky - 앱마다 붙이는 메모")
                        .font(.custom("Paperlogy-6SemiBold", size: 18))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text(.language))
                        .font(.headline)

                    Picker(language.text(.language), selection: Binding(
                        get: { language },
                        set: {
                            storedLanguage = $0.rawValue
                            NoteStore.saveLanguage($0)
                            onChange?()
                        }
                    )) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.title(displayedIn: self.language)).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle(language.text(.launchAtLogin), isOn: Binding(
                        get: { launchAtLogin },
                        set: { updateLaunchAtLogin($0) }
                    ))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text(.defaultNewNote))
                        .font(.headline)

                    settingsRow(title: language.text(.defaultBackground)) {
                        Picker(language.text(.defaultBackground), selection: Binding(
                            get: { selectedThemeID },
                            set: {
                                selectedThemeID = $0
                                NoteStore.saveDefaultThemeID($0)
                                onChange?()
                            }
                        )) {
                            ForEach(BuiltInThemes.all) { theme in
                                HStack {
                                    Circle()
                                        .fill(theme.backgroundColor)
                                        .frame(width: 10, height: 10)
                                    Text(theme.displayName(language: language))
                                }
                                .tag(theme.id)
                            }
                        }
                        .labelsHidden()
                    }

                    settingsRow(title: language.text(.defaultTextColor)) {
                        Picker(language.text(.defaultTextColor), selection: Binding(
                            get: { selectedTextColor },
                            set: {
                                selectedTextColor = $0
                                NoteStore.saveDefaultTextColor($0 < 0 ? nil : UInt32($0))
                                onChange?()
                            }
                        )) {
                            Text(language.text(.systemTextColor)).tag(-1)
                            ForEach(SettingsTextColorOption.all) { option in
                                HStack {
                                    Circle()
                                        .fill(Color(hex: option.color))
                                        .frame(width: 10, height: 10)
                                    Text(option.title(language: language))
                                }
                                .tag(Int(option.color))
                            }
                        }
                        .labelsHidden()
                    }
                }

                Divider()

                Button(language.text(.shortcutSettings)) {
                    openShortcutSettings?()
                }

                Divider()

                HStack(spacing: 10) {
                    Button(language.text(.termsAndPolicies)) {
                        openExternalURL(termsAndPoliciesURL)
                    }
                    Button(language.text(.developerApps)) {
                        openExternalURL(developerAppsURL)
                    }
                    Spacer()
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 420)
    }

    private func settingsRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

struct ShortcutSettingsView: View {
    @AppStorage("appLanguage") private var storedLanguage = AppLanguage.korean.rawValue
    @FocusState private var focusedAction: AppShortcutAction?
    @State private var shortcutByAction = Dictionary(
        uniqueKeysWithValues: AppShortcutAction.configurableCases.map { ($0, $0.savedShortcut()) }
    )
    @State private var keyInputByAction = Dictionary(
        uniqueKeysWithValues: AppShortcutAction.configurableCases.map { ($0, $0.savedShortcut().characters) }
    )
    @State private var conflictByAction: [AppShortcutAction: AppShortcutAction] = [:]

    var onChange: (() -> Void)? = nil

    private var language: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .korean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.text(.shortcutSettings))
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(AppShortcutAction.configurableCases) { action in
                        shortcutRow(for: action)
                        Divider()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedAction = nil
        }
        .padding(22)
        .frame(width: 640, height: 450)
        .onAppear {
            reload()
        }
    }

    private func shortcutRow(for action: AppShortcutAction) -> some View {
        let shortcut = shortcutByAction[action] ?? action.defaultShortcut

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(action.title(language: language))
                    .frame(width: 140, alignment: .leading)

                HStack(spacing: 6) {
                    Toggle("⌘", isOn: modifierBinding(for: action, \.usesCommand))
                        .frame(width: 44, alignment: .leading)
                    Toggle("⌥", isOn: modifierBinding(for: action, \.usesOption))
                        .frame(width: 44, alignment: .leading)
                    Toggle("⌃", isOn: modifierBinding(for: action, \.usesControl))
                        .frame(width: 44, alignment: .leading)
                    Toggle("⇧", isOn: modifierBinding(for: action, \.usesShift))
                        .frame(width: 44, alignment: .leading)
                }
                .toggleStyle(.checkbox)

                TextField(language.text(.shortcutKey), text: Binding(
                    get: { keyInputByAction[action] ?? shortcut.characters },
                    set: { updateShortcutKey($0, for: action) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.center)
                .focused($focusedAction, equals: action)

                Text(shortcut.displayText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)

                Spacer()

                Button(language.text(.resetShortcut)) {
                    resetShortcut(for: action)
                }
            }

            if let conflictedAction = conflictByAction[action] {
                Text(language.shortcutConflictText(conflictedAction.title(language: language)))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 152)
            }
        }
        .frame(minHeight: 32)
    }

    private func modifierBinding(
        for action: AppShortcutAction,
        _ keyPath: WritableKeyPath<AppShortcut, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { (shortcutByAction[action] ?? action.defaultShortcut)[keyPath: keyPath] },
            set: { value in
                var next = shortcutByAction[action] ?? action.defaultShortcut
                next[keyPath: keyPath] = value
                guard next.isValid else { return }
                trySave(next, for: action)
            }
        )
    }

    private func updateShortcutKey(_ input: String, for action: AppShortcutAction) {
        let candidate = String(input.suffix(1)).uppercased()
        let current = shortcutByAction[action] ?? action.defaultShortcut
        guard let next = AppShortcut.shortcut(forInput: candidate, basedOn: current) else {
            keyInputByAction[action] = current.characters
            return
        }
        keyInputByAction[action] = next.characters
        trySave(next, for: action)
    }

    private func resetShortcut(for action: AppShortcutAction) {
        AppShortcutStore.reset(action)
        let shortcut = action.defaultShortcut
        shortcutByAction[action] = shortcut
        keyInputByAction[action] = shortcut.characters
        conflictByAction[action] = nil
        onChange?()
    }

    private func trySave(_ shortcut: AppShortcut, for action: AppShortcutAction) {
        if let conflictedAction = conflictingAction(for: shortcut, excluding: action) {
            conflictByAction[action] = conflictedAction
            keyInputByAction[action] = shortcutByAction[action]?.characters ?? action.defaultShortcut.characters
            return
        }

        conflictByAction[action] = nil
        shortcutByAction[action] = shortcut
        keyInputByAction[action] = shortcut.characters
        AppShortcutStore.save(shortcut, for: action)
        onChange?()
    }

    private func conflictingAction(for shortcut: AppShortcut, excluding action: AppShortcutAction) -> AppShortcutAction? {
        AppShortcutAction.configurableCases.first { otherAction in
            guard otherAction != action else { return false }
            let otherShortcut = shortcutByAction[otherAction] ?? otherAction.savedShortcut()
            return otherShortcut == shortcut
        }
    }

    private func reload() {
        AppShortcutAction.configurableCases.forEach { action in
            let shortcut = action.savedShortcut()
            shortcutByAction[action] = shortcut
            keyInputByAction[action] = shortcut.characters
        }
        conflictByAction = [:]
    }
}

struct DeletedNotesRestoreView: View {
    @AppStorage("appLanguage") private var storedLanguage = AppLanguage.korean.rawValue
    @State private var deletedNotes = NoteStore.deletedNotes()
    var restoreNote: (StickerNote) -> Void

    private var language: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .korean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.text(.restoreDeletedNotes))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button(language.text(.refresh)) {
                    refresh()
                }
            }

            Divider()

            if deletedNotes.isEmpty {
                Spacer()
                Text(language.text(.noDeletedNotes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(deletedNotes) { deletedNote in
                            deletedNoteRow(deletedNote)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460, height: 420)
        .onAppear {
            refresh()
        }
    }

    private func deletedNoteRow(_ deletedNote: DeletedStickerNote) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(BuiltInThemes.theme(id: deletedNote.note.themeID).backgroundColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text(deletedNote.previewTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(deletedDateText(deletedNote.deletedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(language.text(.restore)) {
                restoreDeletedNote(deletedNote)
            }
        }
        .padding(.vertical, 10)
    }

    private func refresh() {
        deletedNotes = NoteStore.deletedNotes()
    }

    private func restoreDeletedNote(_ deletedNote: DeletedStickerNote) {
        guard let note = NoteStore.restoreDeletedNote(id: deletedNote.id) else { return }
        restoreNote(note)
        refresh()
    }

    private func deletedDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .korean ? "ko_KR" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct SettingsTextColorOption: Identifiable {
    let englishTitle: String
    let koreanTitle: String
    let color: UInt32

    var id: UInt32 { color }

    static let all: [SettingsTextColorOption] = [
        SettingsTextColorOption(englishTitle: "Ink", koreanTitle: "잉크", color: 0x202020),
        SettingsTextColorOption(englishTitle: "White", koreanTitle: "화이트", color: 0xFFFFFF),
        SettingsTextColorOption(englishTitle: "Blue", koreanTitle: "블루", color: 0x1558DD),
        SettingsTextColorOption(englishTitle: "Pink", koreanTitle: "핑크", color: 0xFF3E9E),
        SettingsTextColorOption(englishTitle: "Yellow", koreanTitle: "옐로우", color: 0xFFF22E),
        SettingsTextColorOption(englishTitle: "Green", koreanTitle: "그린", color: 0x09B875)
    ]

    func title(language: AppLanguage) -> String {
        language == .korean ? koreanTitle : englishTitle
    }
}
