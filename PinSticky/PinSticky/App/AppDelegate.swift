import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var language = NoteStore.savedLanguage()
    private var defaultThemeID = NoteStore.savedDefaultThemeID()
    private var defaultTextColor = NoteStore.savedDefaultTextColor()
    private var stores: [NoteStore] = []
    private var noteWindowControllers: [UUID: NoteWindowController] = [:]
    private var activeNoteID: UUID?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var deletedNotesWindow: NSWindow?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
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
        observeActiveApplications()
        startWindowVisibilityPolling()
        installKeyMonitor()
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
        windowVisibilityTimer?.invalidate()
        noteWindowControllers.values.forEach { $0.captureCurrentFrame() }
        stores.forEach { $0.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showNote() {
        isShowingAllNotesUntilAppSwitch = true
        NSApp.activate()
        showAllNotes(forceVisible: true)
        DispatchQueue.main.async { [weak self] in
            self?.showAllNotes(forceVisible: true)
        }
    }

    @objc private func newNote() {
        createNote(inheriting: nil)
    }

    @objc private func newNoteWithTheme(_ sender: NSMenuItem) {
        createNote(inheriting: nil, themeID: sender.representedObject as? String)
    }

    private func createNote(inheriting note: StickerNote?, themeID: String? = nil) {
        let noteStore = NoteStore.makeNew(offset: stores.count, inheriting: note, themeID: themeID)
        stores.append(noteStore)
        show(store: noteStore, forceVisible: noteStore.note.displayMode == .always || isShowingAllNotesUntilAppSwitch)
        NSApp.activate()
    }

    @objc private func workspaceApplicationsChanged(_ notification: Notification) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            !application.isTerminated,
            let bundleIdentifier = bundleIdentifier(forRunningApplicationWithPID: application.processIdentifier) {
            if notification.name == NSWorkspace.didActivateApplicationNotification,
               application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                isShowingAllNotesUntilAppSwitch = false
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

    @objc private func cycleTheme() {
        activeController?.store.cycleTheme()
    }

    @objc private func closeNote() {
        activeController?.hide()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "PinSticky",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        ])
    }

    @objc private func showSettings() {
        NSApp.activate()

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = language.text(.settings)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(onChange: { [weak self] in
            self?.refreshPreferencesFromSettings()
        }))
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func showDeletedNotesRestore() {
        NSApp.activate()

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
        settingsWindow?.title = language.text(.settings)
        deletedNotesWindow?.title = language.text(.restoreDeletedNotes)
        stores.forEach { $0.updateLanguage(language) }
        configureStatusItem()
    }

    private func configureStatusItem() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinSticky") ?? NSImage(named: NSImage.touchBarGoDownTemplateName)
        item.button?.imagePosition = .imageOnly
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(statusMenuItem(title: language.text(.about), action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(newNoteMenuItem())
        menu.addItem(statusMenuItem(title: language.text(.showNote), action: #selector(showNote), keyEquivalent: "s"))
        menu.addItem(statusMenuItem(title: language.text(.collapseExpand), action: #selector(toggleCollapse), keyEquivalent: "d"))
        menu.addItem(statusMenuItem(title: language.text(.nextTheme), action: #selector(cycleTheme), keyEquivalent: "t"))
        menu.addItem(statusMenuItem(title: language.text(.closeNote), action: #selector(closeNote), keyEquivalent: "w"))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(title: language.text(.settings), action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(statusMenuItem(title: language.text(.restoreDeletedNotes), action: #selector(showDeletedNotesRestore)))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem(title: language.text(.quit), action: #selector(quit), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private func showAllNotes(forceVisible: Bool = false, activateShownNotes: Bool = true) {
        stores.forEach { show(store: $0, forceVisible: forceVisible, activateShownNote: activateShownNotes) }
    }

    private func refreshNoteVisibilityForVisibleApps() {
        guard !isShowingAllNotesUntilAppSwitch else {
            showAllNotes(forceVisible: true, activateShownNotes: false)
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

    private func show(store: NoteStore, forceVisible: Bool = false, activateShownNote: Bool = true) {
        let controller = noteWindowControllers[store.note.id] ?? NoteWindowController(store: store) { [weak self] in
            self?.createNote(inheriting: store.note)
        } deleteNote: { [weak self] noteID in
            self?.deleteNote(id: noteID)
        } activateNote: { [weak self] noteID in
            self?.activate(noteID: noteID)
        } noteFrameChanged: { [weak self] in
            self?.refreshOverlapOutlines()
        } visibilityContext: { [weak self] in
            self?.currentVisibilityContext() ?? (nil, [])
        }
        noteWindowControllers[store.note.id] = controller
        if activateShownNote {
            activate(noteID: store.note.id)
        }
        controller.show(forceVisible: forceVisible)
        refreshOverlapOutlines()
    }

    private func activate(noteID: UUID) {
        activeNoteID = noteID
        noteWindowControllers[noteID]?.bringToFront()
        refreshOverlapOutlines()
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

    private func deleteNote(id: UUID) {
        noteWindowControllers[id]?.close()
        noteWindowControllers[id] = nil
        if let index = stores.firstIndex(where: { $0.note.id == id }) {
            NoteStore.archiveDeletedNote(stores[index].note)
            stores[index].deleteFile()
            stores.remove(at: index)
        }

        activeNoteID = stores.last?.note.id
        if !stores.isEmpty {
            showAllNotes(forceVisible: isShowingAllNotesUntilAppSwitch)
        } else {
            refreshOverlapOutlines()
        }
    }

    private func restoreDeleted(_ note: StickerNote) {
        guard !stores.contains(where: { $0.note.id == note.id }) else {
            return
        }
        let restoredStore = NoteStore.makeRestored(note: note)
        stores.append(restoredStore)
        show(store: restoredStore, forceVisible: restoredStore.note.displayMode == .always || isShowingAllNotesUntilAppSwitch)
        NSApp.activate()
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

    private func statusMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func newNoteMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: language.text(.newNote), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let defaultItem = NSMenuItem(title: language.text(.defaultNewNote), action: #selector(newNote), keyEquivalent: "n")
        defaultItem.target = self
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
            return self.handleStatusShortcut(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                _ = self?.handleStatusShortcut(event)
            }
        }
    }

    func handleStatusShortcut(_ event: NSEvent) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }

        switch event.pinStickyShortcutKey {
        case .newNote:
            newNote()
        case .showAll:
            showNote()
        case .collapseExpand:
            toggleCollapse()
        case .nextTheme:
            cycleTheme()
        case .closeNote:
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
}
