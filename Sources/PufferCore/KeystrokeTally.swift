import Foundation

/// How many keystrokes Puffer has saved: for each expansion, the characters
/// it inserted minus the keys typed to get them. Kept on this Mac only.
public struct KeystrokeTally: Codable, Equatable, Sendable {
    /// Each is celebrated once, the first time the total passes it.
    public static let milestones = [1_000, 10_000, 100_000, 1_000_000]

    /// How long the menu keeps celebrating a milestone.
    static let celebration: TimeInterval = 24 * 60 * 60

    public private(set) var total: Int
    /// The highest milestone passed so far, 0 for none.
    public private(set) var reached: Int
    public private(set) var reachedAt: Date?

    public init(total: Int = 0, reached: Int = 0, reachedAt: Date? = nil) {
        self.total = total
        self.reached = reached
        self.reachedAt = reachedAt
    }

    /// Characters inserted minus keys typed: the characters the expansion
    /// deletes plus the key that fired it, which is swallowed. Never below
    /// zero: a shortcode longer than its text saves nothing, and so does
    /// an emoji picked by name.
    public static func saving(of expansion: Expansion) -> Int {
        max(0, expansion.text.count - (expansion.deleteCount + 1))
    }

    /// Counts an expansion. Returns the milestone it passed, if it passed
    /// one for the first time (the highest, if it passed several).
    @discardableResult
    public mutating func expanded(_ expansion: Expansion, at date: Date) -> Int? {
        total += Self.saving(of: expansion)
        guard let passed = Self.milestones.last(where: { $0 <= total }), passed > reached else { return nil }
        reached = passed
        reachedAt = date
        return passed
    }

    /// Takes an undone expansion's saving back. `undo` is the edit that
    /// undid it: it deletes what was inserted and types back what was typed.
    public mutating func undid(_ undo: Expansion) {
        total = max(0, total - max(0, undo.deleteCount - undo.text.count))
    }

    /// The menu's line, or nil before anything has been saved.
    public func menuTitle(now: Date, locale: Locale = .current) -> String? {
        guard total > 0 else { return nil }
        let count = total.formatted(.number.locale(locale))
        let line = "Saved \(count) keystroke\(total == 1 ? "" : "s")"
        // Not after an undo took the total back below the milestone.
        if let reachedAt, total >= reached, now.timeIntervalSince(reachedAt) < Self.celebration {
            return "🐡 \(line) — past \(reached.formatted(.number.locale(locale)))!"
        }
        return line
    }
}
