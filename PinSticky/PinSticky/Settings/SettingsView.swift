import SwiftUI

struct SettingsView: View {
    @AppStorage("appLanguage") private var storedLanguage = AppLanguage.korean.rawValue
    @State private var selectedThemeID = NoteStore.savedDefaultThemeID()
    @State private var selectedTextColor = NoteStore.savedDefaultTextColor().map(Int.init) ?? -1

    var onChange: (() -> Void)? = nil

    private var language: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .korean
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pin Sticky - 앱마다 붙이는 메모")
                    .font(.custom("Paperlogy-7Bold", size: 22))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

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

                VStack(alignment: .leading, spacing: 8) {
                    Button(language.text(.termsAndPolicies)) {}
                        .disabled(true)
                    Button(language.text(.developerApps)) {}
                        .disabled(true)
                }
            }
            .padding(22)
        }
        .frame(width: 420, height: 360)
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
