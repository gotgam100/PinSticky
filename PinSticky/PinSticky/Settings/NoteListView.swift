import SwiftUI

struct NoteListView: View {
    @AppStorage("appLanguage") private var storedLanguage = AppLanguage.korean.rawValue
    @State private var query = ""
    @State private var selectedNoteIDs = Set<UUID>()

    let stores: [NoteStore]
    let runningApps: [RunningApplicationInfo]
    let showNote: (NoteStore) -> Void
    let attachNote: (NoteStore, RunningApplicationInfo?) -> Void
    let attachNotes: ([NoteStore], RunningApplicationInfo?) -> Void
    let deleteNotes: ([NoteStore]) -> Void

    private var language: AppLanguage {
        AppLanguage(rawValue: storedLanguage) ?? .korean
    }

    private var filteredStores: [NoteStore] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return stores.sorted { $0.note.updatedAt > $1.note.updatedAt }
        }

        return stores
            .filter { store in
                store.note.content.localizedCaseInsensitiveContains(trimmedQuery)
                    || store.note.attachedAppName?.localizedCaseInsensitiveContains(trimmedQuery) == true
                    || BuiltInThemes.theme(id: store.note.themeID).displayName(language: language).localizedCaseInsensitiveContains(trimmedQuery)
            }
            .sorted { $0.note.updatedAt > $1.note.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text(.noteList))
                .font(.system(size: 20, weight: .bold, design: .rounded))

            TextField(language.text(.searchNotes), text: $query)
                .textFieldStyle(.roundedBorder)

            Divider()

            if filteredStores.isEmpty {
                Spacer()
                Text(language.text(.noSearchResults))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(spacing: 12) {
                    Button(selectionButtonTitle) {
                        toggleAllSelection()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(width: 74, alignment: .leading)

                    Spacer()

                    Text(language.text(.pinningStatus))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)

                    Spacer()
                        .frame(width: 22)
                }
                .padding(.horizontal, 2)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredStores, id: \.note.id) { store in
                            NoteListRowView(
                                store: store,
                                language: language,
                                runningApps: runningApps,
                                isSelected: selectedNoteIDs.contains(store.note.id),
                                toggleSelection: {
                                    toggleSelection(for: store)
                                },
                                showNote: showNote,
                                attachNote: { store, application in
                                    attachFromRow(store, to: application)
                                },
                                deleteNote: { store in
                                    deleteFromRow(store)
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 480, height: 440)
        .onChange(of: stores.map(\.note.id)) { _, noteIDs in
            selectedNoteIDs = selectedNoteIDs.intersection(Set(noteIDs))
        }
    }

    private var selectedStores: [NoteStore] {
        stores.filter { selectedNoteIDs.contains($0.note.id) }
    }

    private var allNoteIDs: Set<UUID> {
        Set(stores.map(\.note.id))
    }

    private var selectionButtonTitle: String {
        allNoteIDs.isSubset(of: selectedNoteIDs) && !stores.isEmpty
            ? language.text(.deselectAll)
            : language.text(.selectAll)
    }

    private func toggleSelection(for store: NoteStore) {
        if selectedNoteIDs.contains(store.note.id) {
            selectedNoteIDs.remove(store.note.id)
        } else {
            selectedNoteIDs.insert(store.note.id)
        }
    }

    private func toggleAllSelection() {
        if allNoteIDs.isSubset(of: selectedNoteIDs), !stores.isEmpty {
            selectedNoteIDs.removeAll()
        } else {
            selectedNoteIDs = allNoteIDs
        }
    }

    private func attachFromRow(_ store: NoteStore, to application: RunningApplicationInfo?) {
        if selectedNoteIDs.contains(store.note.id), !selectedStores.isEmpty {
            attachNotes(selectedStores, application)
        } else {
            attachNote(store, application)
        }
    }

    private func deleteFromRow(_ store: NoteStore) {
        let storesToDelete: [NoteStore]
        if selectedNoteIDs.contains(store.note.id), !selectedStores.isEmpty {
            storesToDelete = selectedStores
        } else {
            storesToDelete = [store]
        }

        deleteNotes(storesToDelete)
        selectedNoteIDs.subtract(storesToDelete.map(\.note.id))
    }
}

private struct NoteListRowView: View {
    @ObservedObject var store: NoteStore
    let language: AppLanguage
    let runningApps: [RunningApplicationInfo]
    let isSelected: Bool
    let toggleSelection: () -> Void
    let showNote: (NoteStore) -> Void
    let attachNote: (NoteStore, RunningApplicationInfo?) -> Void
    let deleteNote: (NoteStore) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(BuiltInThemes.theme(id: store.note.themeID).backgroundColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: store.note))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer()

            Menu(pinningTitle(for: store.note)) {
                Button(language.text(.alwaysVisible)) {
                    attachNote(store, nil)
                }

                if !runningApps.isEmpty {
                    Divider()
                }

                ForEach(runningApps) { app in
                    Button {
                        attachNote(store, app)
                    } label: {
                        if store.note.attachedBundleIdentifier == app.bundleIdentifier {
                            Label(displayName(for: app, language: language), systemImage: "checkmark")
                        } else {
                            Text(displayName(for: app, language: language))
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 96, alignment: .trailing)

            Button {
                deleteNote(store)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(language.text(.deleteNote))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showNote(store)
        }
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .padding(.vertical, 10)
    }

    private func title(for note: StickerNote) -> String {
        let firstLine = note.content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine, !firstLine.isEmpty else {
            return language.text(.untitledNote)
        }
        return firstLine
    }

    private func pinningTitle(for note: StickerNote) -> String {
        switch note.displayMode {
        case .always:
            return language.text(.alwaysVisible)
        case .unpinned:
            return language.text(.unpinned)
        case .whenAppIsActive:
            let appName = attachedAppName(for: note)
            return appName
        }
    }

    private func attachedAppName(for note: StickerNote) -> String {
        guard let bundleIdentifier = note.attachedBundleIdentifier else {
            return note.attachedAppName ?? language.text(.notAttached)
        }

        if let runningApp = runningApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return displayName(for: runningApp, language: language)
        }

        let storedName = note.attachedAppName ?? bundleIdentifier
        return displayName(storedName, bundleIdentifier: bundleIdentifier, language: language)
    }
}

private func displayName(for application: RunningApplicationInfo, language: AppLanguage) -> String {
    displayName(application.name, bundleIdentifier: application.bundleIdentifier, language: language)
}

private func displayName(_ name: String, bundleIdentifier: String, language: AppLanguage) -> String {
    guard language == .english else { return name }
    if let englishName = commonEnglishAppName(for: bundleIdentifier) {
        return englishName
    }
    return name.containsHangul ? bundleIdentifier : name
}

private func commonEnglishAppName(for bundleIdentifier: String) -> String? {
    [
        "com.apple.finder": "Finder",
        "com.apple.Safari": "Safari",
        "com.apple.TextEdit": "TextEdit",
        "com.apple.Notes": "Notes",
        "com.apple.mail": "Mail",
        "com.apple.iCal": "Calendar",
        "com.apple.MobileSMS": "Messages",
        "com.apple.reminders": "Reminders",
        "com.apple.Preview": "Preview",
        "com.apple.Photos": "Photos",
        "com.apple.Music": "Music",
        "com.apple.AppStore": "App Store",
        "com.apple.systempreferences": "System Settings",
        "com.apple.systemsettings": "System Settings"
    ][bundleIdentifier]
}

private extension String {
    var containsHangul: Bool {
        unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(Int(scalar.value))
                || (0x1100...0x11FF).contains(Int(scalar.value))
                || (0x3130...0x318F).contains(Int(scalar.value))
        }
    }
}
