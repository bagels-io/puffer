import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PufferCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let model = LibraryModel()
    private let engine = ExpansionEngine()
    private var statusItem: NSStatusItem!
    /// The Puffer menu in the main menu bar, shown while a Puffer window is
    /// in front. It repeats the settings from the menu bar icon's menu, so
    /// they stay reachable when the icon is hidden.
    private var appMenu: NSMenu!
    private var editorWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var statusTimer: Timer?
    /// Set when macOS refuses the event tap although the permission is granted.
    private var engineFailedToStart = false
    private var startAttempts = 0
    /// True from a launch without the permission until it is first granted:
    /// that is when to open the editor and offer the login item.
    private var isFirstRun = false
    private var iconAnimator: StatusIconAnimator!
    private let expansionSound = ExpansionSound()
    private var tally = AppDelegate.loadTally()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        setUpStatusItem()

        engine.setEntries(model.library.allEntries)
        setUpEmoji()
        engine.onExpanded = { [weak self] expansion, kind in
            self?.expanded(expansion, kind)
        }
        model.onChange = { [engine] library in
            engine.setEntries(library.allEntries)
        }

        if AXIsProcessTrusted() {
            startEngine()
            offerLaunchAtLoginOnFirstRun()
        } else {
            isFirstRun = true
            showPermissionWindow()
        }

        // Once a second: start the engine when the permission arrives, stop
        // it if the permission is taken away, and keep the menu bar icon
        // honest. In the common modes so that it also runs while a menu or
        // an alert is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveNow()
    }

    /// Launching Puffer again while it is running opens the editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEditor()
        return false
    }

    // MARK: - Launch at login

    private var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// A text expander is only useful if it is always running, but adding a
    /// login item is the user's decision: ask, once.
    private func offerLaunchAtLoginOnFirstRun() {
        let key = "didOfferLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Only register an installed copy: a login item pointing into a
        // build folder breaks as soon as that folder is cleaned.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard !launchesAtLogin else { return }

        let alert = NSAlert()
        alert.messageText = "Open Puffer when you log in?"
        alert.informativeText = """
        Shortcodes only expand while Puffer is running. You can change this \
        at any time with “Launch at Login” in Puffer’s menu.
        """
        alert.addButton(withTitle: "Launch at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            setLaunchAtLogin(true)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Puffer: could not change the login item: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchesAtLogin)
    }

    // MARK: - Accessibility permission

    /// Creates the event tap. macOS sometimes refuses it for a moment just
    /// after the permission is granted, so `checkStatus` tries again each
    /// second, and after five failures the menu reports it.
    private func startEngine() {
        startAttempts += 1
        if engine.start() {
            engineFailedToStart = false
            startAttempts = 0
        } else if startAttempts >= 5 {
            NSLog("Puffer: could not create the event tap")
            engineFailedToStart = true
            startAttempts = 0
        }
        updateStatusIcon()
    }

    @objc private func retryStartingEngine() {
        engineFailedToStart = false
        startAttempts = 0
        startEngine()
    }

    /// Runs every second. The one place that reacts to the permission being
    /// granted or taken away, whichever window or menu led to it.
    private func checkStatus() {
        if !AXIsProcessTrusted() {
            // Switched off in System Settings. A tap left in place without
            // the permission can hold up the whole keyboard, so remove it
            // at once and ask again.
            if engine.isRunning {
                engine.stop()
                showPermissionWindow()
            }
            engineFailedToStart = false
            startAttempts = 0
        } else if !engine.isRunning, !engineFailedToStart {
            startEngine()
            // Granted: the window that asked for it has done its job, even
            // if the tap needs another try (the menu says so if it fails).
            if permissionWindow?.isVisible == true { permissionWindow?.close() }
            if isFirstRun, engine.isRunning {
                isFirstRun = false
                showEditor()
                offerLaunchAtLoginOnFirstRun()
            }
        }
        updateStatusIcon()
    }

    /// Why shortcodes are not expanding although Puffer is running, if they
    /// are not. Shown in the menu and by a dimmed icon.
    private var pauseReason: String? {
        if engine.isPaused { return nil } // the Pause item's tick says it
        if NSApp.isActive { return "Paused while Puffer’s window is in front" }
        if let holder = secureInputHolder { return "Paused: \(holder) has secure input on" }
        if engine.inputMethodIsSelected { return "Paused: an input method is selected" }
        return nil
    }

    /// The app holding secure input on, if another app is. While it is on,
    /// macOS hides all typing from Puffer. That is right for a password
    /// field, but some apps leave it on by mistake and expansion then stops
    /// everywhere with no other sign.
    private var secureInputHolder: String? {
        guard IsSecureEventInputEnabled(), !NSApp.isActive else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if let pid = session?["kCGSSessionSecureInputPID"] as? Int32,
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        return "another app"
    }

    @objc private func requestPermission() {
        // Adds Puffer to the Accessibility list (and shows the system prompt
        // the first time), then opens that pane.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showPermissionWindow() {
        if permissionWindow == nil {
            let view = PermissionView(openSettings: { [weak self] in self?.requestPermission() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Puffer"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            permissionWindow = window
        }
        present(permissionWindow)
    }

    // MARK: - Editor window

    @objc private func showEditor() {
        if editorWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(model: model)))
            window.title = "Puffer"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 900, height: 560))
            window.center()
            window.setFrameAutosaveName("PufferEditor")
            editorWindow = window
        }
        present(editorWindow)
    }

    /// Menu bar apps have no Dock icon; show one while a window is open so
    /// the window can be reached with Command-Tab.
    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === editorWindow { model.saveNow() }
        let othersOpen = [editorWindow, permissionWindow].contains { window in
            guard let window, window !== closing else { return false }
            return window.isVisible
        }
        if !othersOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Menu bar item

    private static let hidesMenuBarIconKey = "hidesMenuBarIcon"

    private var showsMenuBarIcon: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.hidesMenuBarIconKey) }
        set {
            UserDefaults.standard.set(!newValue, forKey: Self.hidesMenuBarIconKey)
            statusItem.isVisible = newValue
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.image = StatusIcon.make()
        statusItem.isVisible = showsMenuBarIcon
        iconAnimator = StatusIconAnimator(button: statusItem.button)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        // Dimmed whenever expansions are not actually happening.
        button.appearsDisabled = engine.isPaused || !engine.isRunning || pauseReason != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === appMenu {
            buildAppMenu(menu)
            return
        }

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(showPermissionWindow)))
            menu.addItem(.separator())
        } else if engineFailedToStart {
            menu.addItem(note("Not running: macOS refused keyboard access"))
            menu.addItem(note("Remove Puffer from Accessibility in System Settings, add it again, then:"))
            menu.addItem(item("Try Again", #selector(retryStartingEngine)))
            menu.addItem(.separator())
        } else if !engine.isRunning {
            menu.addItem(note("Starting…"))
            menu.addItem(.separator())
        } else if let reason = pauseReason {
            menu.addItem(note(reason))
            menu.addItem(.separator())
        }

        if let saved = tally.menuTitle(now: Date()) {
            menu.addItem(note(saved))
            menu.addItem(.separator())
        }
        menu.addItem(item("Open Puffer…", #selector(showEditor)))
        addSettings(to: menu)
        menu.addItem(item("Hide Menu Bar Icon…", #selector(hideMenuBarIcon)))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Puffer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func buildAppMenu(_ menu: NSMenu) {
        // Expansion is always off while this menu is open (a Puffer window
        // is in front), so only a failure is worth reporting here.
        if AXIsProcessTrusted(), engineFailedToStart {
            menu.addItem(note("Not running: macOS refused keyboard access"))
            menu.addItem(item("Try Again", #selector(retryStartingEngine)))
            menu.addItem(.separator())
        }
        let icon = item("Show Menu Bar Icon", #selector(toggleMenuBarIcon))
        icon.state = showsMenuBarIcon ? .on : .off
        menu.addItem(icon)
        addSettings(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Puffer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Puffer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Pause, login item and library location: in both the menu bar icon's
    /// menu and the Puffer menu.
    private func addSettings(to menu: NSMenu) {
        let pause = item("Pause Expansion", #selector(togglePause))
        pause.state = engine.isPaused ? .on : .off
        menu.addItem(pause)

        let emoji = item("Emoji Suggestions", #selector(toggleEmojiSuggestions))
        emoji.state = emojiSuggestionsEnabled ? .on : .off
        menu.addItem(emoji)

        let sound = item("Expansion Sound", #selector(toggleExpansionSound))
        sound.state = expansionSoundEnabled ? .on : .off
        menu.addItem(sound)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = launchesAtLogin ? .on : .off
        menu.addItem(login)

        let location = NSMenuItem(title: "Library Location", action: nil, keyEquivalent: "")
        location.submenu = makeLocationMenu()
        menu.addItem(location)
    }

    @objc private func hideMenuBarIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide Puffer’s menu bar icon?"
        alert.informativeText = """
        Puffer keeps running and expanding your shortcodes. To get back to it, \
        open Puffer again from Applications or Spotlight. Its window’s Puffer \
        menu has the same settings, and “Show Menu Bar Icon” brings the icon back.
        """
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showsMenuBarIcon = false
    }

    @objc private func toggleMenuBarIcon() {
        showsMenuBarIcon.toggle()
    }

    /// A line of status text in the menu.
    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Library location

    private func makeLocationMenu() -> NSMenu {
        let menu = NSMenu()
        let path = NSMenuItem(
            title: (model.storageDirectory.path as NSString).abbreviatingWithTildeInPath,
            action: nil,
            keyEquivalent: ""
        )
        path.isEnabled = false
        menu.addItem(path)
        menu.addItem(item("Show in Finder", #selector(showLibraryInFinder)))
        menu.addItem(.separator())
        menu.addItem(item("Choose Folder…", #selector(chooseLibraryFolder)))
        let reset = item("Use Default Folder", #selector(useDefaultLibraryFolder))
        if model.isAtDefaultLocation {
            reset.action = nil
            reset.isEnabled = false
        }
        menu.addItem(reset)
        return menu
    }

    @objc private func showLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [model.storageDirectory.appendingPathComponent(LibraryStore.fileName)]
        )
    }

    @objc private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Library Location"
        panel.message = "Choose the folder Puffer keeps its library in. Pick a synced folder to share it between Macs."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.storageDirectory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        moveLibrary(to: folder)
    }

    @objc private func useDefaultLibraryFolder() {
        moveLibrary(to: LibraryStore.defaultDirectory)
    }

    private func moveLibrary(to folder: URL) {
        let destination = LibraryStore(directory: folder)
        if destination.exists, destination.fileURL.standardizedFileURL
            != LibraryStore(directory: model.storageDirectory).fileURL.standardizedFileURL {
            let alert = NSAlert()
            alert.messageText = "Use the library already in “\(folder.lastPathComponent)”?"
            alert.informativeText = """
            That folder already contains a Puffer library, so Puffer will switch to it. \
            Your current library stays where it is, in \
            \((model.storageDirectory.path as NSString).abbreviatingWithTildeInPath).
            """
            alert.addButton(withTitle: "Use That Library")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try model.relocate(to: folder)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The library could not be moved"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func togglePause() {
        engine.isPaused.toggle()
        updateStatusIcon()
    }

    // MARK: - Emoji suggestions

    private static let emojiDisabledKey = "emojiSuggestionsDisabled"
    private static let emojiRecentsKey = "emojiRecents"
    private static let maxEmojiRecents = 12

    private lazy var emojiPopup = EmojiPopup { [weak self] index in
        self?.engine.chooseEmoji(at: index)
    }

    private var emojiSuggestionsEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.emojiDisabledKey) }
        set {
            UserDefaults.standard.set(!newValue, forKey: Self.emojiDisabledKey)
            engine.emojiEnabled = newValue
        }
    }

    // MARK: - Puff, pop and tally

    private static let expansionSoundKey = "expansionSound"
    private static let tallyKey = "keystrokeTally"

    /// Off until switched on: it is heard many times an hour.
    private var expansionSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.expansionSoundKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.expansionSoundKey) }
    }

    @objc private func toggleExpansionSound() {
        expansionSoundEnabled.toggle()
        if expansionSoundEnabled { expansionSound.play() }
    }

    private static func loadTally() -> KeystrokeTally {
        guard let data = UserDefaults.standard.data(forKey: tallyKey),
              let tally = try? JSONDecoder().decode(KeystrokeTally.self, from: data) else { return KeystrokeTally() }
        return tally
    }

    /// Something was just injected: count it, and puff (and pop) unless it
    /// was an undo. Passing a milestone puffs three times.
    private func expanded(_ expansion: Expansion, _ kind: ExpansionKind) {
        let milestone: Int?
        switch kind {
        case .undo:
            tally.undid(expansion)
            milestone = nil
        case .shortcode, .emoji:
            milestone = tally.expanded(expansion, at: Date())
        }
        if let data = try? JSONEncoder().encode(tally) {
            UserDefaults.standard.set(data, forKey: Self.tallyKey)
        }
        guard kind != .undo else { return }
        if expansionSoundEnabled { expansionSound.play() }
        if showsMenuBarIcon { iconAnimator.puff(times: milestone == nil ? 1 : 3) }
    }

    private func setUpEmoji() {
        engine.emojiEnabled = emojiSuggestionsEnabled
        engine.setEmojiRecents(UserDefaults.standard.stringArray(forKey: Self.emojiRecentsKey) ?? [])
        emojiPopup.onFrameChange = { [weak self] frame in
            self?.engine.setEmojiPanel(visibleFrame: frame)
        }
        engine.onEmojiPopup = { [weak self] command in
            self?.emojiPopup.handle(command)
        }
        engine.onEmojiInserted = { [weak self] emoji in
            self?.rememberRecentEmoji(emoji)
        }
    }

    /// Only the emoji is kept, never what was typed around it.
    private func rememberRecentEmoji(_ emoji: Emoji) {
        var recents = UserDefaults.standard.stringArray(forKey: Self.emojiRecentsKey) ?? []
        recents.removeAll { $0 == emoji.character }
        recents.insert(emoji.character, at: 0)
        recents = Array(recents.prefix(Self.maxEmojiRecents))
        UserDefaults.standard.set(recents, forKey: Self.emojiRecentsKey)
        engine.setEmojiRecents(recents)
    }

    @objc private func toggleEmojiSuggestions() {
        emojiSuggestionsEnabled.toggle()
    }

    // MARK: - Main menu

    /// Without a main menu, Command-C/V/X/Z/A/W/Q do nothing in our windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        // Filled in by `menuNeedsUpdate`, which keeps the Command-H and
        // Command-Q key equivalents working.
        appMenu = NSMenu(title: "Puffer")
        appMenu.delegate = self
        buildAppMenu(appMenu)
        main.addItem(submenu(appMenu, title: "Puffer"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(find)
        main.addItem(submenu(editMenu, title: "Edit"))

        return main
    }

    @objc private func focusSearch() {
        showEditor()
        model.searchFocusRequests += 1
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
