import AppKit

/// Puffs the menu bar pufferfish up and back down.
@MainActor
final class StatusIconAnimator {
    /// One puff, up and down.
    static let puffDuration: TimeInterval = 0.35

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var started = Date()
    private var duration: TimeInterval = 0

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// Puffs `times` times in a row. While a puff is under way, it finishes
    /// and the new ones follow, rather than snapping back to the start.
    func puff(times: Int = 1) {
        guard button != nil, times > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = Date()
        if timer != nil {
            let elapsed = now.timeIntervalSince(started)
            let endOfCurrent = (floor(elapsed / Self.puffDuration) + 1) * Self.puffDuration
            duration = max(duration, endOfCurrent + Double(times - 1) * Self.puffDuration)
            return
        }
        started = now
        duration = Double(times) * Self.puffDuration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // Common modes: keep animating while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < duration else {
            button?.image = StatusIcon.make()
            timer?.invalidate()
            timer = nil
            return
        }
        let phase = elapsed.truncatingRemainder(dividingBy: Self.puffDuration) / Self.puffDuration
        button?.image = StatusIcon.make(puff: sin(.pi * phase))
    }
}

/// The soft pop played when something expands, if switched on.
@MainActor
final class ExpansionSound {
    /// Quiet: it is heard many times an hour.
    static let volume: Float = 0.35

    /// "Interface Sounds" by Kenney (kenney.nl), CC0.
    private let sound: NSSound? = Bundle.main.url(forResource: "Pop", withExtension: "caf")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    init() {
        sound?.volume = Self.volume
    }

    func play() {
        guard let sound else { return }
        // Expansions in quick succession: start again rather than skip.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
