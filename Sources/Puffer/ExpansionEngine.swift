import AppKit
import Carbon.HIToolbox
import os
import PufferCore

/// What the emoji popup should do. Delivered on the main thread.
enum EmojiPopupCommand {
    case show(matches: [Emoji], selected: Int)
    case hide
}

/// Watches keystrokes system-wide through a `CGEventTap`, feeds them to the
/// `Matcher`, and hands any resulting expansion to the `TextInjector`.
///
/// Threads: the tap has a thread of its own, so that nothing the rest of the
/// app does (file I/O, the editor, a slow clipboard) can delay a keystroke
/// on its way to the app the user is typing in. Everything marked "tap
/// thread only" is touched from that thread and nowhere else; the main
/// thread reaches it through `onTapThread`. The public API is main-thread.
final class ExpansionEngine {
    // MARK: - Main-thread API

    /// While paused the tap is switched off, so no key press reaches Puffer
    /// at all.
    var isPaused = false {
        didSet {
            let paused = isPaused
            onTapThread { [self] in
                self.paused = paused
                abandonInjection()
                if let tap { CGEvent.tapEnable(tap: tap, enable: !paused) }
            }
        }
    }

    /// Whether an input method, rather than a plain keyboard layout, is
    /// selected. Nothing expands while one is. Main thread.
    var inputMethodIsSelected: Bool { !(keyboard?.state.isPlainLayout ?? true) }

    private(set) var isRunning = false

    init() {
        tapRunLoop = Self.startTapThread()
        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observeAppState()
        keyboard = KeyboardWatcher { [weak self] state in
            self?.injector.setPasteKeyCode(state.pasteKeyCode)
            self?.onTapThread {
                self?.inputMethodIsActive = !state.isPlainLayout
                self?.resetTyping()
            }
        }
    }

    private var keyboard: KeyboardWatcher?

    // MARK: - Emoji suggestions (main-thread API)

    /// Whether typing `:` and a name offers emoji.
    var emojiEnabled = true {
        didSet {
            let enabled = emojiEnabled
            onTapThread { [self] in
                emojiOn = enabled
                endEmojiSession()
            }
        }
    }

    /// Asked to show or hide the popup. Called on the main thread.
    var onEmojiPopup: ((EmojiPopupCommand) -> Void)?
    /// An emoji was inserted. Called on the main thread.
    var onEmojiInserted: ((Emoji) -> Void)?

    func setEmojiRecents(_ recents: [String]) {
        onTapThread { [self] in session.recents = recents }
    }

    /// The popup's frame in global top-left coordinates while it is on
    /// screen, nil while it is not. The popup's keys are only taken while
    /// it is visible, so nothing is inserted that the user never saw.
    func setEmojiPanel(visibleFrame: CGRect?) {
        panelFrame.withLock { $0 = visibleFrame }
    }

    /// The user clicked a row of the popup.
    func chooseEmoji(at index: Int) {
        onTapThread { [self] in
            guard activeInjection == nil else { return }
            apply(session.choose(index: index))
        }
    }

    /// Read by the tap thread, written by the main thread.
    private let panelFrame = OSAllocatedUnfairLock<CGRect?>(initialState: nil)

    func setEntries(_ entries: [Entry]) {
        onTapThread { [self] in matcher.setEntries(entries) }
    }

    /// Creates the event tap. Fails (returns false) until the Accessibility
    /// permission has been granted.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        var created = false
        onTapThreadAndWait { [self] in created = createTap() }
        isRunning = created
        return created
    }

    /// Removes the event tap, e.g. when the permission has been taken away.
    func stop() {
        guard isRunning else { return }
        onTapThreadAndWait { [self] in destroyTap() }
        isRunning = false
    }

    // MARK: - Tap thread

    private let tapRunLoop: CFRunLoop

    /// Starts the thread the tap lives on and returns its run loop.
    private static func startTapThread() -> CFRunLoop {
        let ready = DispatchSemaphore(value: 0)
        var runLoop: CFRunLoop!
        let thread = Thread {
            runLoop = CFRunLoopGetCurrent()
            // A run loop with nothing attached returns at once; this timer
            // (which never fires) keeps it alive before and between taps.
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0
            ) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = "puffer.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return runLoop
    }

    private func onTapThread(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(tapRunLoop)
    }

    /// The tap thread never waits on the main thread, so this cannot deadlock.
    private func onTapThreadAndWait(_ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        onTapThread {
            work()
            done.signal()
        }
        done.wait()
    }

    /// Keeps the tap thread's copy of app-level state current.
    private func observeAppState() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            // The user is now typing somewhere else.
            self?.onTapThread {
                self?.frontBundleID = bundleID
                self?.resetTyping()
            }
        }

        let center = NotificationCenter.default
        for (name, active) in [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false),
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onTapThread {
                    self?.ownAppIsActive = active
                    self?.resetTyping()
                }
            }
        }
    }

    // MARK: - Tap thread only

    private var matcher = Matcher()
    private var session = EmojiSession()
    private var emojiOn = true
    /// The app being typed in. Emoji suggestions are off in some apps.
    private var frontBundleID: String?
    /// Popup keys whose key-down was swallowed: their key-up is swallowed
    /// too, so an app that acts on key-up never sees a lone Return.
    private var swallowedKeyCodes: Set<Int64> = []
    private let injector = TextInjector()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var paused = false
    /// Whether Puffer itself is the frontmost app.
    private var ownAppIsActive = false
    /// Whether an input method, rather than a plain keyboard layout, is on.
    private var inputMethodIsActive = false

    /// Counts injections, so each one's final event can be told apart.
    private var lastInjection: Int64 = 0
    /// The injection whose events are still on their way to the app, if any.
    private var activeInjection: Int64?
    /// Keys the user pressed while an injection was in flight. They are held
    /// back so they cannot land in the middle of it, then replayed in order.
    private var held: [CGEvent] = []
    /// Releases the held keys if an injection never reports that it finished.
    private var watchdog: CFRunLoopTimer?
    /// Clears the matcher when the user stops typing, so that what they
    /// last typed does not sit in memory indefinitely.
    private var idleTimer: CFRunLoopTimer?
    private static let idleClearDelay: CFTimeInterval = 10

    private func createTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ExpansionEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(tapRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: !paused)
        self.tap = tap
        tapSource = source
        resetTyping()
        return true
    }

    private func destroyTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(tapRunLoop, tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        abandonInjection()
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it is ever slow; switch it back on.
            if let tap, !paused { CGEvent.tapEnable(tap: tap, enable: true) }
            resetTyping()
            // An injection may still be posting. Letting the held keys go
            // now would put them ahead of it, so keep waiting for its final
            // event, but not for long: that event may have gone by while
            // the tap was off.
            if activeInjection != nil { armWatchdog(after: 1) }
            return passThrough
        case .keyDown, .keyUp:
            break
        default:
            // A click in the emoji popup chooses an emoji; the popup reports
            // it through `chooseEmoji(at:)`, so the session must survive it.
            if let frame = panelFrame.withLock({ $0 }), frame.contains(event.location) {
                return passThrough
            }
            // Any other mouse click may have moved the insertion point.
            resetTyping()
            return passThrough
        }

        // Keystrokes Puffer generated itself.
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if TextInjector.isOwnEvent(userData) {
            // The last event of an injection: everything it posted is now
            // ahead of this point in the event stream, so the keys held back
            // meanwhile can follow.
            if let serial = TextInjector.finalSerial(userData), serial == activeInjection {
                finishInjection(proxy: proxy)
            }
            return passThrough
        }

        if type == .keyUp,
           swallowedKeyCodes.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil {
            return nil
        }

        // While an injection is in flight, hold the user's keys back: let
        // through now, they would arrive before the expansion or be eaten
        // by its backspaces.
        if activeInjection != nil, let copy = event.copy() {
            held.append(copy)
            return nil
        }

        // Key-ups are only watched so they can be held in order with key-downs.
        if type == .keyUp { return passThrough }

        // Arrows, Return, Tab and Escape belong to the emoji popup while it
        // is on screen.
        if session.isActive, let key = Self.popupKey(for: event) {
            restartIdleTimer()
            let result = session.press(key, popupVisible: panelFrame.withLock { $0 } != nil)
            apply(result.outcome)
            if result.swallow {
                swallowedKeyCodes.insert(event.getIntegerValueField(.keyboardEventKeycode))
                return nil
            }
        }

        if let expansion = expansion(for: event) {
            begin(expansion)
            return nil // swallow the key that fired it; the injector types what is needed
        }
        return passThrough
    }

    /// Feeds a key-down the user typed to the matcher. Returns what to
    /// inject when it completes a shortcode or undoes an expansion.
    private func expansion(for event: CGEvent) -> Expansion? {
        // Never expand while secure input is on (password fields), while
        // paused, inside Puffer's own editor (typing a shortcode into its
        // shortcode field would fire), or while an input method is composing
        // the text (its raw key presses are not what ends up on the page).
        if paused || ownAppIsActive || inputMethodIsActive || IsSecureEventInputEnabled() {
            resetTyping()
            return nil
        }

        // Command/Control combinations are shortcuts, not typing.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            resetTyping()
            return nil
        }

        restartIdleTimer()

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Delete {
            // Option-delete removes a whole word; we can't know how much.
            if flags.contains(.maskAlternate) {
                resetTyping()
                return nil
            }
            // Delete straight after an expansion: put the shortcode back.
            if let undo = matcher.backspace() {
                endEmojiSession()
                return undo
            }
            if emojiAllowedHere { apply(session.backspace()) }
            return nil
        }

        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        let typed = String(utf16CodeUnits: units, count: length)

        // Arrows, return, tab, escape, function keys and so on produce
        // control or private-use characters (or nothing): the caret moved.
        guard !typed.isEmpty, typed.unicodeScalars.allSatisfy(Self.isTextScalar) else {
            resetTyping()
            return nil
        }

        for character in typed {
            if let expansion = matcher.type(character) {
                // A library shortcode wins over an emoji being looked up.
                endEmojiSession()
                return expansion
            }
            if emojiAllowedHere { apply(session.type(character)) }
        }
        return nil
    }

    // MARK: - Emoji sessions (tap thread only)

    private var emojiAllowedHere: Bool {
        emojiOn && EmojiApps.suggestionsAllowed(in: frontBundleID)
    }

    /// Forgets what was typed: the caret may have moved.
    private func resetTyping() {
        matcher.reset()
        endEmojiSession()
    }

    private func endEmojiSession() {
        apply(session.reset())
    }

    private func apply(_ outcome: EmojiSession.Outcome) {
        switch outcome {
        case .none:
            break
        case .show(let matches, let selected):
            if matches.isEmpty {
                hidePopup()
            } else {
                post(.show(matches: matches, selected: selected))
            }
        case .end:
            hidePopup()
        case .insert(let expansion, let emoji, let typed):
            hidePopup()
            matcher.remember(inserted: expansion.text, typed: typed)
            begin(expansion)
            DispatchQueue.main.async { [weak self] in self?.onEmojiInserted?(emoji) }
        }
    }

    private func hidePopup() {
        // Stop taking the popup's keys now, not when the main thread gets
        // round to hiding it.
        panelFrame.withLock { $0 = nil }
        post(.hide)
    }

    private func post(_ command: EmojiPopupCommand) {
        DispatchQueue.main.async { [weak self] in self?.onEmojiPopup?(command) }
    }

    private static func popupKey(for event: CGEvent) -> EmojiSession.Key? {
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate) || flags.contains(.maskShift) {
            return nil
        }
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Tab: return .tab
        case kVK_Escape: return .escape
        default: return nil
        }
    }

    // MARK: - Injections in flight (tap thread only)

    private func begin(_ expansion: Expansion) {
        lastInjection += 1
        activeInjection = lastInjection
        // Far longer than an injection should take. If its final event has
        // not come back by then, something went wrong; let the keys go.
        // Backspaces and typed chunks take a few milliseconds each; a paste
        // takes the same time whatever its length.
        let typedEvents = Double(expansion.text.utf16.count) / Double(Typing.maxUnitsPerEvent)
        armWatchdog(after: min(6, 2 + Double(expansion.deleteCount) * 0.005 + typedEvents * 0.005))
        injector.perform(expansion, serial: lastInjection)
    }

    /// The injection's last event has reached the tap. Replays the keys
    /// held back while it was in flight, straight after it and in order.
    private func finishInjection(proxy: CGEventTapProxy) {
        activeInjection = nil
        disarmWatchdog()
        while !held.isEmpty {
            let event = held.removeFirst()
            // A held key can itself complete a shortcode (typing two in a
            // row quickly). The rest then stay held behind that injection.
            if event.type == .keyDown, let expansion = expansion(for: event) {
                begin(expansion)
                return
            }
            release(event) { $0.tapPostEvent(proxy) }
        }
    }

    /// Gives up waiting for an injection: the tap was switched off or
    /// removed, or the injection's final event never arrived. The held keys
    /// are let go so the keyboard is never left swallowed.
    private func abandonInjection() {
        activeInjection = nil
        disarmWatchdog()
        resetTyping()
        let events = held
        held.removeAll()
        for event in events {
            release(event) { $0.post(tap: .cgSessionEventTap) }
        }
    }

    /// Sends a held key on its way, marked so that the tap lets it straight
    /// through if it sees it again.
    private func release(_ event: CGEvent, post: (CGEvent) -> Void) {
        event.setIntegerValueField(.eventSourceUserData, value: TextInjector.marker())
        post(event)
    }

    /// Called on every key that reaches the matcher.
    private func restartIdleTimer() {
        if idleTimer == nil {
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0
            ) { [weak self] _ in
                self?.resetTyping()
            }
            CFRunLoopAddTimer(tapRunLoop, timer, .commonModes)
            idleTimer = timer
        }
        CFRunLoopTimerSetNextFireDate(idleTimer, CFAbsoluteTimeGetCurrent() + Self.idleClearDelay)
    }

    private func armWatchdog(after seconds: Double) {
        if watchdog == nil {
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0
            ) { [weak self] _ in
                guard let self, self.activeInjection != nil else { return }
                NSLog("Puffer: an injection did not finish in time; releasing held keys")
                self.abandonInjection()
            }
            CFRunLoopAddTimer(tapRunLoop, timer, .commonModes)
            watchdog = timer
        }
        CFRunLoopTimerSetNextFireDate(watchdog, CFAbsoluteTimeGetCurrent() + seconds)
    }

    private func disarmWatchdog() {
        if let watchdog {
            CFRunLoopTimerSetNextFireDate(watchdog, CFAbsoluteTimeGetCurrent() + 1e10)
        }
    }

    private static func isTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0..<0x20, 0x7F: return false            // control characters
        case 0xF700...0xF8FF: return false           // AppKit function-key range
        default: return true
        }
    }
}
