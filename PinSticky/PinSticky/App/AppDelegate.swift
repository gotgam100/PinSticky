import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

private let globalNewNoteHotKeyIDValue: UInt32 = 1
private let globalNewNoteHotKeySignature = fourCharacterCode("PSTK")

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var language = NoteStore.savedLanguage()
    private var defaultThemeID = NoteStore.savedDefaultThemeID()
    private var defaultTextColor = NoteStore.savedDefaultTextColor()
    private var defaultOpacity = NoteStore.savedDefaultOpacity()
    private var defaultLiquidGlassEnabled = NoteStore.savedDefaultLiquidGlassEnabled()
    private var globalNewNoteShortcut = GlobalNewNoteShortcut.saved()
    private var stores: [NoteStore] = []
    private var noteWindowControllers: [UUID: NoteWindowController] = [:]
    private let noteSelectionState = NoteSelectionState()
    private var activeNoteID: UUID?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var shortcutSettingsWindow: NSWindow?
    private var noteListWindow: NSWindow?
    private var deletedNotesWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMagnifyMonitor: Any?
    private var globalMagnifyMonitor: Any?
    private var globalNewNoteHotKeyRef: EventHotKeyRef?
    private var globalNewNoteHotKeyHandler: EventHandlerRef?
    private var isGlobalNewNoteHotKeyRegistered = false
    private var windowVisibilityTimer: Timer?
    private var lastExternalFrontmostBundleIdentifier: String?
    private var lastExternalFrontmostPID: pid_t?
    private var lastVisibleExternalBundleIdentifiers: Set<String> = []
    private var isShowingAllNotesUntilAppSwitch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()
        seedCurrentExternalFrontmostApplication()
        stores = NoteStore.loadAll()
        for store in stores {
            if store.note.stackParentID == nil && !store.note.stackedNoteIDs.isEmpty {
                updateStackStates(for: store.note.id)
            }
        }
        observeActiveApplications()
        startWindowVisibilityPolling()
        installKeyMonitor()
        installMagnifyHoverMonitor()
        registerGlobalNewNoteHotKey()
        configureStatusItem()
        showAllNotes()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localMagnifyMonitor {
            NSEvent.removeMonitor(localMagnifyMonitor)
        }
        if let globalMagnifyMonitor {
            NSEvent.removeMonitor(globalMagnifyMonitor)
        }
        unregisterGlobalNewNoteHotKey()
        windowVisibilityTimer?.invalidate()
        noteWindowControllers.values.forEach { $0.captureCurrentFrame() }
        stores.forEach { $0.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidResignActive(_ notification: Notification) {
        restoreNoteWindowLevels()
    }

    @objc private func showNote() {
        guard hasOpenNoteWindow else {
            isShowingAllNotesUntilAppSwitch = false
            return
        }

        isShowingAllNotesUntilAppSwitch = true
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        temporarilyRevealAttachmentHiddenNotes()
        DispatchQueue.main.async { [weak self] in
            self?.temporarilyRevealAttachmentHiddenNotes()
        }
    }

    @objc private func newNote() {
        createNote(inheriting: nil)
    }

    @objc private func globalNewNote() {
        createGlobalNote(centeredAt: currentMouseLocation())
    }

    private func createGlobalNote(centeredAt centerPoint: CGPoint) {
        createNote(inheriting: nil, centeredAt: centerPoint, forceVisible: true)
    }

    @objc private func newNoteWithTheme(_ sender: NSMenuItem) {
        createNote(inheriting: nil, themeID: sender.representedObject as? String)
    }

    private var lastCreateNoteTime: Date = .distantPast

    private func createNote(
        inheriting note: StickerNote?,
        themeID: String? = nil,
        centeredAt centerPoint: CGPoint? = nil,
        near sourceFrame: CGRect? = nil,
        forceVisible: Bool? = nil
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastCreateNoteTime) > 0.1 else { return }
        lastCreateNoteTime = now
        let noteStore = NoteStore.makeNew(
            offset: stores.count,
            inheriting: note,
            themeID: themeID,
            centeredAt: centerPoint,
            near: sourceFrame,
            avoiding: currentVisibleNoteFrames()
        )
        stores.append(noteStore)
        show(
            store: noteStore,
            forceVisible: forceVisible ?? (noteStore.note.displayMode == .always || isShowingAllNotesUntilAppSwitch)
        )
        updateNoteListWindowContent()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func workspaceApplicationsChanged(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            !application.isTerminated,
            let bundleIdentifier = bundleIdentifier(forRunningApplicationWithPID: application.processIdentifier) {
            if notification.name == NSWorkspace.didActivateApplicationNotification,
               application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                isShowingAllNotesUntilAppSwitch = false
                restoreNoteWindowLevels()
            }
            lastExternalFrontmostBundleIdentifier = bundleIdentifier
            lastExternalFrontmostPID = application.processIdentifier
        }
        refreshNoteVisibilityForVisibleApps()
    }

    @objc private func visibleWindowsChanged() {
        refreshNoteVisibilityForVisibleApps()
    }

    @objc private func toggleCollapse() {
        activeController?.toggleCollapsed()
    }

    @objc private func toggleActiveNoteSelection() {
        activeController?.toggleSelected()
    }

    @objc private func cycleTheme() {
        guard let activeStore = activeController?.store else { return }
        activeStore.cycleTheme()
        let newThemeID = activeStore.note.themeID
        headerSelectedStores(source: activeStore).forEach { $0.updateTheme(newThemeID) }
    }

    @objc private func closeNote() {
        guard let noteID = activeController?.store.note.id else { return }
        deleteNote(id: noteID)
    }

    @objc private func closeAllNotes() {
        guard confirm(message: language.text(.closeAllNotesConfirmation)) else { return }
        isShowingAllNotesUntilAppSwitch = false
        stores.map(\.note.id).forEach { deleteNote(id: $0) }
    }

    @objc private func clearAllAttachments() {
        let activeControllers = noteWindowControllers.values.filter { !$0.isUserHidden }
        guard !activeControllers.isEmpty else { return }
        guard confirm(message: language.text(.clearAllAttachmentsConfirmation)) else { return }
        activeControllers.forEach { $0.store.setAlwaysVisible() }
        refreshNoteVisibilityForVisibleApps()
    }

    @objc private func attachAllNotesToApp(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? RunningApplicationInfo else { return }
        let activeControllers = noteWindowControllers.values.filter { !$0.isUserHidden }
        guard !activeControllers.isEmpty else { return }
        activeControllers.forEach { $0.store.attach(to: application) }
        isShowingAllNotesUntilAppSwitch = false
        refreshNoteVisibilityForVisibleApps()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let appIcon = NSApp.applicationIconImage ?? NSImage()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PinSticky",
            .applicationIcon: appIcon,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        ])
    }

    @objc private func showSettings() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = language.text(.settings)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(
            onChange: { [weak self] in
                self?.refreshPreferencesFromSettings()
            },
            openShortcutSettings: { [weak self] in
                self?.showShortcutSettings()
            }
        ))
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func showShortcutSettings() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let shortcutSettingsWindow {
            shortcutSettingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = language.text(.shortcutSettings)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: ShortcutSettingsView(onChange: { [weak self] in
            self?.refreshPreferencesFromSettings()
        }))
        window.makeKeyAndOrderFront(nil)
        shortcutSettingsWindow = window
    }

    @objc private func showNoteList() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let noteListWindow {
            noteListWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = language.text(.noteList)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        updateNoteListWindowContent(window)
        window.makeKeyAndOrderFront(nil)
        noteListWindow = window
    }

    @objc private func showDeletedNotesRestore() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let deletedNotesWindow {
            deletedNotesWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = language.text(.restoreDeletedNotes)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 460, height: 420)
        window.maxSize = NSSize(width: 460, height: 420)
        window.center()
        window.contentView = NSHostingView(rootView: DeletedNotesRestoreView { [weak self] note in
            self?.restoreDeleted(note)
        })
        window.makeKeyAndOrderFront(nil)
        deletedNotesWindow = window
    }

    private func refreshPreferencesFromSettings() {
        language = NoteStore.savedLanguage()
        defaultThemeID = NoteStore.savedDefaultThemeID()
        defaultTextColor = NoteStore.savedDefaultTextColor()
        let nextDefaultOpacity = NoteStore.savedDefaultOpacity()
        let nextDefaultLiquidGlassEnabled = NoteStore.savedDefaultLiquidGlassEnabled()
        if defaultOpacity != nextDefaultOpacity {
            stores.forEach { $0.updateOpacity(nextDefaultOpacity) }
            defaultOpacity = nextDefaultOpacity
        }
        if defaultLiquidGlassEnabled != nextDefaultLiquidGlassEnabled {
            stores.forEach { $0.updateLiquidGlassEnabled(nextDefaultLiquidGlassEnabled) }
            defaultLiquidGlassEnabled = nextDefaultLiquidGlassEnabled
        }
        globalNewNoteShortcut = GlobalNewNoteShortcut.saved()
        settingsWindow?.title = language.text(.settings)
        shortcutSettingsWindow?.title = language.text(.shortcutSettings)
        noteListWindow?.title = language.text(.noteList)
        deletedNotesWindow?.title = language.text(.restoreDeletedNotes)
        stores.forEach { $0.updateLanguage(language) }
        registerGlobalNewNoteHotKey()
        configureStatusItem()
    }

    private func updateNoteListWindowContent(_ window: NSWindow? = nil) {
        guard let window = window ?? noteListWindow else { return }
        window.contentView = NSHostingView(rootView: NoteListView(
            stores: listedStores(),
            runningApps: runningApplicationOptions(),
            showNote: { [weak self] store in
                self?.showListedNote(store)
            },
            attachNote: { [weak self] store, application in
                self?.attachListedNote(store, to: application)
            },
            attachNotes: { [weak self] stores, application in
                self?.attachListedNotes(stores, to: application)
            },
            deleteNotes: { [weak self] stores in
                self?.deleteListedNotes(stores)
            }
        ))
    }

    private func listedStores() -> [NoteStore] {
        stores.filter { store in
            store.note.stackParentID == nil && noteWindowControllers[store.note.id]?.isUserHidden != true
        }
    }

    private func configureStatusItem() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinSticky") ?? NSImage(named: NSImage.touchBarGoDownTemplateName)
        item.button?.imagePosition = .imageOnly
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(newNoteMenuItem())
        menu.addItem(statusMenuItem(title: language.text(.noteList), iconName: "list.bullet.rectangle", action: #selector(showNoteList), shortcutAction: .noteList))
        menu.addItem(statusMenuItem(title: language.text(.showNote), iconName: "rectangle.stack", action: #selector(showNote), shortcutAction: .showAll))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(title: language.text(.selectNote), iconName: "checkmark.square", action: #selector(toggleActiveNoteSelection), shortcutAction: .selectNote))
        menu.addItem(statusMenuItem(title: language.text(.collapseExpand), iconName: "arrow.down.right.and.arrow.up.left", action: #selector(toggleCollapse), shortcutAction: .collapseExpand))
        menu.addItem(statusMenuItem(title: language.text(.nextTheme), iconName: "paintpalette", action: #selector(cycleTheme), shortcutAction: .nextTheme))
        menu.addItem(statusMenuItem(title: language.text(.closeNote), iconName: "xmark.circle", action: #selector(closeNote), shortcutAction: .closeNote))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(title: language.text(.restoreDeletedNotes), iconName: "arrow.clockwise.circle", action: #selector(showDeletedNotesRestore)))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(title: language.text(.settings), iconName: "gearshape", action: #selector(showSettings), shortcutAction: .settings))
        menu.addItem(statusMenuItem(title: language.text(.about), iconName: "info.circle", action: #selector(showAbout)))
        menu.addItem(statusMenuItem(title: language.text(.quit), iconName: "power", action: #selector(quit), shortcutAction: .quit))

        item.menu = menu
        statusItem = item
    }

    private func showAllNotes(forceVisible: Bool = false, activateShownNotes: Bool = true) {
        pruneControllersWithoutStores()
        stores.forEach { show(store: $0, forceVisible: forceVisible, activateShownNote: activateShownNotes) }
    }

    private func temporarilyRevealAttachmentHiddenNotes() {
        pruneControllersWithoutStores()
        guard hasOpenNoteWindow else {
            isShowingAllNotesUntilAppSwitch = false
            return
        }

        stores.forEach { store in
            show(store: store, activateShownNote: false, resetManualHidden: false)
            let controller = noteWindowControllers[store.note.id]
            controller?.revealIfHiddenByAttachment()
            controller?.bringToFrontForTemporaryReveal()
        }
        refreshOverlapOutlines()
    }

    private var hasOpenNoteWindow: Bool {
        noteWindowControllers.values.contains { $0.visibleFrame != nil }
    }

    private func currentVisibleNoteFrames() -> [CGRect] {
        noteWindowControllers.values.compactMap(\.visibleFrame)
    }

    private func refreshNoteVisibilityForVisibleApps() {
        guard !isShowingAllNotesUntilAppSwitch else {
            temporarilyRevealAttachmentHiddenNotes()
            refreshOverlapOutlines()
            return
        }

        let context = currentVisibilityContext()
        noteWindowControllers.values.forEach {
            $0.refreshVisibility(
                frontmostBundleIdentifier: context.frontmostBundleIdentifier,
                visibleBundleIdentifiers: context.visibleBundleIdentifiers
            )
        }
        refreshOverlapOutlines()
    }

    private func currentVisibilityContext() -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>) {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return retainedExternalVisibilityContext()
        }

        if frontmostApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return retainedExternalVisibilityContext()
        }

        guard let frontmostBundleIdentifier = bundleIdentifier(forRunningApplicationWithPID: frontmostApplication.processIdentifier) else {
            return retainedExternalVisibilityContext()
        }

        lastExternalFrontmostBundleIdentifier = frontmostBundleIdentifier
        lastExternalFrontmostPID = frontmostApplication.processIdentifier
        return (frontmostBundleIdentifier, visibleExternalBundleIdentifiers())
    }

    private func retainedExternalVisibilityContext() -> (frontmostBundleIdentifier: String?, visibleBundleIdentifiers: Set<String>) {
        guard let bundleIdentifier = lastExternalFrontmostBundleIdentifier else {
            return (nil, [])
        }
        return (bundleIdentifier, visibleExternalBundleIdentifiers())
    }

    private func show(
        store: NoteStore,
        forceVisible: Bool = false,
        activateShownNote: Bool = true,
        resetManualHidden: Bool = true
    ) {
        guard stores.contains(where: { $0.note.id == store.note.id }) else { return }
        let isNewController = noteWindowControllers[store.note.id] == nil
        let controller = noteWindowControllers[store.note.id] ?? NoteWindowController(
            store: store,
            newNote: { [weak self] sourceFrame in
                self?.createNote(inheriting: store.note, near: sourceFrame)
            },
            deleteNote: { [weak self] noteID in
                self?.deleteNote(id: noteID)
            },
            activateNote: { [weak self] noteID in
                self?.activate(noteID: noteID)
            },
            noteFrameChanged: { [weak self] in
                self?.syncStackFrames(from: store.note.id)
                self?.refreshOverlapOutlines()
            },
            selectionState: noteSelectionState,
            attachNotes: { [weak self] sourceStore, application in
                self?.attachHeaderSelectedNotes(source: sourceStore, to: application)
            },
            unpinNotes: { [weak self] sourceStore in
                self?.unpinHeaderSelectedNotes(source: sourceStore)
            },
            updateThemeForSelection: { [weak self] sourceStore, themeID in
                self?.updateHeaderSelectedNotesTheme(source: sourceStore, themeID: themeID)
            },
            updateFontSizeForSelection: { [weak self] sourceStore, delta in
                self?.updateHeaderSelectedNotesFontSize(source: sourceStore, delta: delta)
            },
            collapseSelection: { [weak self] sourceStore in
                self?.collapseHeaderSelectedNotes(source: sourceStore)
            },
            stackNote: { [weak self] targetID, refID in
                self?.stackNote(targetID, onto: refID)
            },
            unstackNote: { [weak self] noteID in
                self?.unstackNote(noteID)
            },
            navigateStack: { [weak self] parentID, delta in
                self?.navigateStack(from: parentID, delta: delta)
            },
            visibilityContext: { [weak self] in
                self?.currentVisibilityContext() ?? (nil, [])
            },
            resizeSelectedNotes: { [weak self] sizeDelta, originDelta, sourceID in
                self?.resizeHeaderSelectedNotes(sizeDelta: sizeDelta, originDelta: originDelta, excluding: sourceID)
            }
        )
        noteWindowControllers[store.note.id] = controller
        if activateShownNote {
            activate(noteID: store.note.id)
        }
        controller.show(
            forceVisible: forceVisible,
            resetManualHidden: resetManualHidden,
            animateAppearance: isNewController
        )
        refreshOverlapOutlines()
    }

    private func pruneControllersWithoutStores() {
        let activeNoteIDs = Set(stores.map(\.note.id))
        noteWindowControllers.keys
            .filter { !activeNoteIDs.contains($0) }
            .forEach { noteID in
                noteWindowControllers[noteID]?.close()
                noteWindowControllers[noteID] = nil
            }
    }

    private func activate(noteID: UUID) {
        activeNoteID = noteID
        restoreNoteWindowLevels()
        noteWindowControllers[noteID]?.bringToFrontForActiveSelection()
        refreshOverlapOutlines()
    }

    private func restoreNoteWindowLevels() {
        noteWindowControllers.values.forEach { $0.restoreDefaultWindowLevel() }
    }

    /// Notes that should receive a batch action (theme, font size, pin
    /// state, collapse, ...) triggered from `source`'s own header.
    ///
    /// This must only fan out to the other checked notes when `source`
    /// itself is checked - previously it fanned out to whatever was checked
    /// *anywhere in the app* regardless of whether `source` was part of
    /// that selection, so editing an unchecked note could still drag along
    /// unrelated checked notes (and vice versa), and two notes merely
    /// sharing a stack had no bearing on this at all - only the checkbox
    /// selection should.
    private func headerSelectedStores(source: NoteStore) -> [NoteStore] {
        guard noteSelectionState.isSelected(source.note.id) else { return [source] }
        let activeStoreByID = Dictionary(uniqueKeysWithValues: stores.map { ($0.note.id, $0) })
        let selectedStores = noteSelectionState.selectedNoteIDs.compactMap { activeStoreByID[$0] }
        return selectedStores.isEmpty ? [source] : selectedStores
    }

    private func resizeHeaderSelectedNotes(sizeDelta: CGSize, originDelta: CGPoint, excluding sourceID: UUID) {
        let selectedIDs = noteSelectionState.selectedNoteIDs
        guard selectedIDs.contains(sourceID) else { return }

        for id in selectedIDs where id != sourceID {
            noteWindowControllers[id]?.resizeBy(sizeDelta: sizeDelta, originDelta: originDelta)
        }
    }

    private func attachHeaderSelectedNotes(source: NoteStore, to application: RunningApplicationInfo?) {
        let targetStores = headerSelectedStores(source: source)
        if let application {
            targetStores.forEach { $0.attach(to: application) }
            isShowingAllNotesUntilAppSwitch = false
        } else {
            targetStores.forEach { $0.setAlwaysVisible() }
        }
        refreshNoteVisibilityForVisibleApps()
        updateNoteListWindowContent()
    }

    private func unpinHeaderSelectedNotes(source: NoteStore) {
        headerSelectedStores(source: source).forEach { $0.setUnpinned() }
        refreshNoteVisibilityForVisibleApps()
        updateNoteListWindowContent()
    }

    private func updateHeaderSelectedNotesTheme(source: NoteStore, themeID: String) {
        headerSelectedStores(source: source).forEach { $0.updateTheme(themeID) }
    }

    private func updateHeaderSelectedNotesFontSize(source: NoteStore, delta: Double) {
        headerSelectedStores(source: source).forEach { store in
            store.updateFontSize(store.note.fontSize + delta)
        }
    }

    private func collapseHeaderSelectedNotes(source: NoteStore) {
        headerSelectedStores(source: source).forEach { store in
            noteWindowControllers[store.note.id]?.collapseIfExpanded()
        }
    }

    private func refreshOverlapOutlines() {
        let visibleControllers = noteWindowControllers.values.compactMap { controller -> (NoteWindowController, CGRect)? in
            guard let frame = controller.visibleFrame else { return nil }
            return (controller, frame)
        }

        noteWindowControllers.values.forEach { controller in
            guard let frame = controller.visibleFrame else {
                controller.setHasOverlap(false)
                return
            }
            let hasOverlap = visibleControllers.contains { otherController, otherFrame in
                otherController.store.note.id != controller.store.note.id
                    && frame.intersects(otherFrame)
            }
            controller.setHasOverlap(hasOverlap)
        }
    }

    private func stackNote(_ targetID: UUID, onto referenceID: UUID) {
        guard targetID != referenceID else { return }
        
        let selectedIDs = noteSelectionState.selectedNoteIDs
        let primaryTargets = selectedIDs.contains(targetID) ? Array(selectedIDs) : [targetID]
        let validTargets = primaryTargets.filter { $0 != referenceID }
        
        guard let refStore = stores.first(where: { $0.note.id == referenceID }) else { return }
        let actualRefID = refStore.note.stackParentID ?? referenceID
        guard let actualRefStore = stores.first(where: { $0.note.id == actualRefID }) else { return }
        
        for target in validTargets {
            guard target != actualRefID else { continue }
            guard let targetStore = stores.first(where: { $0.note.id == target }) else { continue }
            
            if targetStore.note.stackParentID != nil {
                unstackNote(target)
            }
            
            let childrenToMove = targetStore.note.stackedNoteIDs
            targetStore.note.stackedNoteIDs.removeAll()
            
            let allTargets = [target] + childrenToMove
            for id in allTargets {
                guard id != actualRefID else { continue }
                if let store = stores.first(where: { $0.note.id == id }) {
                    store.note.stackParentID = actualRefID
                    if !actualRefStore.note.stackedNoteIDs.contains(id) {
                        actualRefStore.note.stackedNoteIDs.append(id)
                    }
                    store.note.expandedFrame = actualRefStore.note.expandedFrame
                    store.note.displayMode = actualRefStore.note.displayMode
                    noteWindowControllers[id]?.hide()
                    store.flush()
                }
            }
        }
        
        noteWindowControllers[actualRefID]?.show(forceVisible: true, resetManualHidden: true, animateAppearance: false)
        actualRefStore.flush()
        updateStackStates(for: actualRefID)
    }

    private func unstackNote(_ noteID: UUID) {
        guard let targetStore = stores.first(where: { $0.note.id == noteID }) else { return }
        guard targetStore.note.stackParentID != nil || !targetStore.note.stackedNoteIDs.isEmpty else { return }

        detachNoteFromStack(noteID)

        targetStore.note.expandedFrame = CodableRect(
            x: targetStore.note.expandedFrame.x + 20,
            y: targetStore.note.expandedFrame.y - 20,
            width: targetStore.note.expandedFrame.width,
            height: targetStore.note.expandedFrame.height
        )
        noteWindowControllers[noteID]?.show(forceVisible: true)
        targetStore.stackIndex = nil
        targetStore.stackCount = nil
        targetStore.flush()
    }

    /// Removes `noteID` from whatever stack it participates in (as a child
    /// or as the parent/reference note) and repairs the remaining stack so
    /// its other pages stay reachable. Does not touch `noteID`'s own window
    /// or `stores` entry — callers decide what happens to the note itself
    /// (kept as a standalone note in `unstackNote`, or deleted entirely in
    /// `deleteNote`).
    private func detachNoteFromStack(_ noteID: UUID) {
        guard let targetStore = stores.first(where: { $0.note.id == noteID }) else { return }

        if let parentID = targetStore.note.stackParentID {
            guard let parentStore = stores.first(where: { $0.note.id == parentID }) else { return }
            targetStore.note.stackParentID = nil
            parentStore.note.stackedNoteIDs.removeAll(where: { $0 == noteID })
            parentStore.flush()
            updateStackStates(for: parentID)
            showStackIfNoneVisible(parentID: parentID)
        } else if !targetStore.note.stackedNoteIDs.isEmpty {
            let remainingChildIDs = targetStore.note.stackedNoteIDs
            guard let firstChildID = remainingChildIDs.first,
                  let firstChildStore = stores.first(where: { $0.note.id == firstChildID }) else { return }

            let otherChildIDs = Array(remainingChildIDs.dropFirst())
            firstChildStore.note.stackedNoteIDs = otherChildIDs
            firstChildStore.note.stackParentID = nil
            for childID in otherChildIDs {
                if let childStore = stores.first(where: { $0.note.id == childID }) {
                    childStore.note.stackParentID = firstChildID
                    childStore.flush()
                }
            }

            targetStore.note.stackedNoteIDs.removeAll()
            firstChildStore.flush()
            updateStackStates(for: firstChildID)
            showStackIfNoneVisible(parentID: firstChildID)
        }
    }

    private func showStackIfNoneVisible(parentID: UUID) {
        guard let parentStore = stores.first(where: { $0.note.id == parentID }) else { return }
        let allIDs = [parentID] + parentStore.note.stackedNoteIDs
        let hasVisible = allIDs.contains { noteWindowControllers[$0]?.isWindowVisible == true }
        if !hasVisible {
            noteWindowControllers[parentID]?.show(forceVisible: true, resetManualHidden: true, animateAppearance: false)
        }
    }

    private func updateStackStates(for parentID: UUID) {
        guard let parentStore = stores.first(where: { $0.note.id == parentID }) else { return }
        let allIDs = [parentID] + parentStore.note.stackedNoteIDs
        let count = allIDs.count
        
        for (index, id) in allIDs.enumerated() {
            if let store = stores.first(where: { $0.note.id == id }) {
                if count > 1 {
                    store.stackIndex = index
                    store.stackCount = count
                } else {
                    store.stackIndex = nil
                    store.stackCount = nil
                }
            }
        }
    }

    func navigateStack(from parentID: UUID, delta: Int) {
        guard let parentStore = stores.first(where: { $0.note.id == parentID }) else { return }
        let allIDs = [parentID] + parentStore.note.stackedNoteIDs
        guard allIDs.count > 1 else { return }
        
        let visibleID = allIDs.first { noteWindowControllers[$0]?.isWindowVisible == true } ?? parentID
        guard let visibleIndex = allIDs.firstIndex(of: visibleID) else { return }
        
        let newIndex = (visibleIndex + delta + allIDs.count) % allIDs.count
        let newVisibleID = allIDs[newIndex]
        
        if visibleID != newVisibleID {
            if let oldStore = stores.first(where: { $0.note.id == visibleID }),
               let newStore = stores.first(where: { $0.note.id == newVisibleID }) {
                newStore.note.expandedFrame = oldStore.note.expandedFrame
            }
            noteWindowControllers[visibleID]?.hide()
            noteWindowControllers[newVisibleID]?.show(forceVisible: true, resetManualHidden: true, animateAppearance: false)
        }
    }
    
    private func syncStackFrames(from sourceID: UUID) {
        guard let sourceStore = stores.first(where: { $0.note.id == sourceID }) else { return }
        let parentID = sourceStore.note.stackParentID ?? sourceID
        guard let parentStore = stores.first(where: { $0.note.id == parentID }) else { return }
        
        let allIDs = [parentID] + parentStore.note.stackedNoteIDs
        let frame = sourceStore.note.expandedFrame
        
        for id in allIDs {
            if id != sourceID, let store = stores.first(where: { $0.note.id == id }) {
                store.note.expandedFrame = frame
            }
        }
    }

    private func deleteNote(id: UUID) {
        detachNoteFromStack(id)
        noteWindowControllers[id]?.close(animated: true)
        noteWindowControllers[id] = nil
        noteSelectionState.remove(id)
        if let index = stores.firstIndex(where: { $0.note.id == id }) {
            NoteStore.archiveDeletedNote(stores[index].note)
            stores[index].deleteFile()
            stores.remove(at: index)
        }

        activeNoteID = stores.last?.note.id
        if !stores.isEmpty {
            refreshNoteVisibilityForVisibleApps()
        } else {
            refreshOverlapOutlines()
        }
        updateNoteListWindowContent()
    }

    private func restoreDeleted(_ note: StickerNote) {
        guard !stores.contains(where: { $0.note.id == note.id }) else {
            return
        }
        let restoredStore = NoteStore.makeRestored(note: note)
        stores.append(restoredStore)
        noteSelectionState.prune(activeNoteIDs: Set(stores.map(\.note.id)))
        show(store: restoredStore, forceVisible: restoredStore.note.displayMode == .always || isShowingAllNotesUntilAppSwitch)
        updateNoteListWindowContent()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showListedNote(_ store: NoteStore) {
        guard stores.contains(where: { $0.note.id == store.note.id }) else { return }
        show(store: store, forceVisible: true)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func attachListedNote(_ store: NoteStore, to application: RunningApplicationInfo?) {
        guard stores.contains(where: { $0.note.id == store.note.id }) else { return }
        if let application {
            store.attach(to: application)
            isShowingAllNotesUntilAppSwitch = false
        } else {
            store.setAlwaysVisible()
        }
        refreshNoteVisibilityForVisibleApps()
        updateNoteListWindowContent()
    }

    private func attachListedNotes(_ selectedStores: [NoteStore], to application: RunningApplicationInfo?) {
        let activeIDs = Set(stores.map(\.note.id))
        let storesToUpdate = selectedStores.filter { activeIDs.contains($0.note.id) }
        guard !storesToUpdate.isEmpty else { return }

        if let application {
            storesToUpdate.forEach { $0.attach(to: application) }
            isShowingAllNotesUntilAppSwitch = false
        } else {
            storesToUpdate.forEach { $0.setAlwaysVisible() }
        }
        refreshNoteVisibilityForVisibleApps()
        updateNoteListWindowContent()
    }

    private func deleteListedNotes(_ selectedStores: [NoteStore]) {
        let activeIDs = Set(stores.map(\.note.id))
        let noteIDsToDelete = selectedStores
            .map(\.note.id)
            .filter { activeIDs.contains($0) }
        guard !noteIDsToDelete.isEmpty else { return }

        noteIDsToDelete.forEach { deleteNote(id: $0) }
    }

    private var activeController: NoteWindowController? {
        if let activeNoteID, let controller = noteWindowControllers[activeNoteID] {
            return controller
        }
        return noteWindowControllers.values.first
    }

    private func observeActiveApplications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ].forEach { notificationName in
            notificationCenter.addObserver(
                self,
                selector: #selector(workspaceApplicationsChanged),
                name: notificationName,
                object: nil
            )
        }
    }

    private func startWindowVisibilityPolling() {
        windowVisibilityTimer?.invalidate()
        windowVisibilityTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(visibleWindowsChanged),
            userInfo: nil,
            repeats: true
        )
        if let windowVisibilityTimer {
            RunLoop.main.add(windowVisibilityTimer, forMode: .common)
        }
    }

    private func seedCurrentExternalFrontmostApplication() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = bundleIdentifier(forRunningApplicationWithPID: frontmostApplication.processIdentifier) else {
            return
        }
        lastExternalFrontmostBundleIdentifier = bundleIdentifier
        lastExternalFrontmostPID = frontmostApplication.processIdentifier
    }

    private func bundleIdentifier(forRunningApplicationWithPID pid: pid_t) -> String? {
        RunningApplicationInfo(applicationPID: pid)?.bundleIdentifier
    }

    private func visibleExternalBundleIdentifiers() -> Set<String> {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return lastVisibleExternalBundleIdentifiers
        }

        var bundleIdentifiers = Set<String>()
        for windowInfo in windowInfoList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  windowInfo[kCGWindowLayer as String] as? Int == 0,
                  (windowInfo[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = windowBounds(from: windowInfo),
                  bounds.width > 1,
                  bounds.height > 1,
                  let application = NSRunningApplication(processIdentifier: ownerPID),
                  !application.isTerminated,
                  !application.isHidden,
                  let applicationInfo = RunningApplicationInfo(application: application) else {
                continue
            }
            bundleIdentifiers.insert(applicationInfo.bundleIdentifier)
        }

        lastVisibleExternalBundleIdentifiers = bundleIdentifiers
        return bundleIdentifiers
    }

    private func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
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

    private func statusMenuItem(
        title: String,
        iconName: String,
        action: Selector,
        shortcutAction: AppShortcutAction? = nil
    ) -> NSMenuItem {
        let shortcut = shortcutAction?.savedShortcut()
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.keyEquivalent ?? "")
        if let shortcut {
            item.keyEquivalentModifierMask = shortcut.menuModifierMask
        }
        item.target = self
        item.image = statusMenuIcon(named: iconName)
        return item
    }

    private func newNoteMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: language.text(.newNote), action: nil, keyEquivalent: "")
        item.image = statusMenuIcon(named: "square.and.pencil")
        let submenu = NSMenu()

        let defaultItem = NSMenuItem(
            title: language.text(.defaultNewNote),
            action: #selector(globalNewNote),
            keyEquivalent: globalNewNoteShortcut.keyEquivalent
        )
        defaultItem.target = self
        defaultItem.keyEquivalentModifierMask = globalNewNoteShortcut.menuModifierMask
        defaultItem.image = themeSwatchImage(BuiltInThemes.theme(id: defaultThemeID))
        submenu.addItem(defaultItem)
        submenu.addItem(.separator())

        BuiltInThemes.all.forEach { theme in
            let themeItem = NSMenuItem(title: theme.displayName(language: language), action: #selector(newNoteWithTheme(_:)), keyEquivalent: "")
            themeItem.target = self
            themeItem.representedObject = theme.id
            themeItem.image = themeSwatchImage(theme)
            submenu.addItem(themeItem)
        }

        item.submenu = submenu
        return item
    }

    private func statusMenuIcon(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func allNotesPinningMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: language.text(.allNotesPinMenu), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let alwaysItem = NSMenuItem(title: language.text(.alwaysVisible), action: #selector(clearAllAttachments), keyEquivalent: "")
        alwaysItem.target = self
        submenu.addItem(alwaysItem)

        let applications = runningApplicationOptions()
        if !applications.isEmpty {
            submenu.addItem(.separator())
        }

        applications.forEach { application in
            let appItem = NSMenuItem(title: application.name, action: #selector(attachAllNotesToApp(_:)), keyEquivalent: "")
            appItem.target = self
            appItem.representedObject = application
            submenu.addItem(appItem)
        }

        item.submenu = submenu
        return item
    }

    private func runningApplicationOptions() -> [RunningApplicationInfo] {
        NSWorkspace.shared.runningApplications
            .compactMap { RunningApplicationInfo(application: $0) }
            .sorted { $0.name < $1.name }
    }

    private func themeSwatchImage(_ theme: NoteTheme) -> NSImage {
        colorSwatchImage(theme.background)
    }

    private func colorSwatchImage(_ color: UInt32) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor(hex: color).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3, yRadius: 3).stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func confirm(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: language.text(.yes))
        alert.addButton(withTitle: language.text(.no))
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
        } else if window === shortcutSettingsWindow {
            shortcutSettingsWindow = nil
        } else if window === noteListWindow {
            noteListWindow = nil
        } else if window === deletedNotesWindow {
            deletedNotesWindow = nil
        }
    }
}

private extension AppDelegate {
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        return mainMenu
    }

    func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleStatusShortcut(event, requireFrontmost: false) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                _ = self?.handleStatusShortcut(event)
            }
        }
    }

    func installMagnifyHoverMonitor() {
        localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self else { return event }
            return self.routeMagnifyToHoveredNote(event) ? nil : event
        }
        globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            Task { @MainActor in
                _ = self?.routeMagnifyToHoveredNote(event)
            }
        }
    }

    func routeMagnifyToHoveredNote(_ event: NSEvent) -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        guard let controller = hoveredNoteController(at: mouseLocation) else { return false }
        controller.handleHoverMagnify(event)
        return true
    }

    func hoveredNoteController(at screenPoint: CGPoint) -> NoteWindowController? {
        for window in NSApp.orderedWindows {
            guard let controller = noteWindowControllers.values.first(where: {
                $0.windowNumber == window.windowNumber && $0.containsScreenPoint(screenPoint)
            }) else {
                continue
            }
            return controller
        }
        return noteWindowControllers.values.first { $0.containsScreenPoint(screenPoint) }
    }

    func registerGlobalNewNoteHotKey() {
        unregisterGlobalNewNoteHotKey()
        guard globalNewNoteShortcut.isValid else { return }

        let eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == globalNewNoteHotKeySignature,
                      hotKeyID.id == globalNewNoteHotKeyIDValue,
                      let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                let mouseLocation = appDelegate.currentMouseLocation()
                Task { @MainActor in
                    appDelegate.createGlobalNote(centeredAt: mouseLocation)
                }
                return noErr
            },
            1,
            [eventSpec],
            Unmanaged.passUnretained(self).toOpaque(),
            &globalNewNoteHotKeyHandler
        )

        guard handlerStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: globalNewNoteHotKeySignature, id: globalNewNoteHotKeyIDValue)
        let hotKeyStatus = RegisterEventHotKey(
            globalNewNoteShortcut.keyCode,
            globalNewNoteShortcut.carbonModifierMask,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &globalNewNoteHotKeyRef
        )

        isGlobalNewNoteHotKeyRegistered = hotKeyStatus == noErr
    }

    func unregisterGlobalNewNoteHotKey() {
        if let globalNewNoteHotKeyRef {
            UnregisterEventHotKey(globalNewNoteHotKeyRef)
            self.globalNewNoteHotKeyRef = nil
        }
        if let globalNewNoteHotKeyHandler {
            RemoveEventHandler(globalNewNoteHotKeyHandler)
            self.globalNewNoteHotKeyHandler = nil
        }
        isGlobalNewNoteHotKeyRegistered = false
    }

    func currentMouseLocation() -> CGPoint {
        NSEvent.mouseLocation
    }

    func handleStatusShortcut(_ event: NSEvent, requireFrontmost: Bool = true) -> Bool {
        // The frontmost-app check exists to stop the *global* monitor from
        // stealing keystrokes meant for some unrelated app. It shouldn't
        // apply to the *local* monitor: since `.nonactivatingPanel` lets a
        // note become the key window (and legitimately receive its
        // keystrokes) without making PinSticky "frontmost" in
        // NSWorkspace's bookkeeping, this guard was rejecting shortcuts
        // like Cmd+T typed while working in a note whenever another app
        // still counted as frontmost - even though the local monitor only
        // ever sees events already routed to our own key window.
        if requireFrontmost {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                return false
            }
        }

        switch AppShortcutAction.matching(event) {
        case .newNote:
            newNote()
        case .noteList:
            showNoteList()
        case .showAll:
            showNote()
        case .selectNote:
            toggleActiveNoteSelection()
        case .collapseExpand:
            toggleCollapse()
        case .nextTheme:
            cycleTheme()
        case .closeNote:
            if closeKeyWindowIfNeeded() {
                return true
            }
            closeNote()
        case .settings:
            showSettings()
        case .quit:
            quit()
        default:
            return false
        }
        return true
    }

    func closeKeyWindowIfNeeded() -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        guard keyWindow === settingsWindow
            || keyWindow === shortcutSettingsWindow
            || keyWindow === noteListWindow
            || keyWindow === deletedNotesWindow
            || keyWindow.className == "NSPanel" && keyWindow.title.contains("PinSticky") else {
            return false
        }

        keyWindow.performClose(nil)
        return true
    }
}
