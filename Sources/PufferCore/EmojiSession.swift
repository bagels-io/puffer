import Foundation

/// Follows what the user types for emoji suggestions: a colon at the start
/// of a word, then the start of a name. Says when the popup should show,
/// what it should list, which keys it takes, and what to insert.
///
/// Pure logic: the engine feeds it keystrokes and acts on the outcomes.
public struct EmojiSession: Sendable {
    /// Keys the popup uses while it is on screen.
    public enum Key: Sendable {
        case up, down, enter, tab, escape
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing for the popup to do.
        case none
        /// Show or refresh the popup. No matches: hide it for now, but the
        /// session goes on (backspacing may bring matches back).
        case show(matches: [Emoji], selected: Int)
        /// The session is over; hide the popup.
        case end
        /// Inject this. `typed` is what it replaces (the colon and the
        /// query), for undo. The session is over.
        case insert(Expansion, emoji: Emoji, typed: String)
    }

    /// Emoji picked recently, most recent first. Listed first when they match.
    public var recents: [String] = []

    /// The last character typed; nil at the start of the text, which is
    /// also what a reset means (the caret may be anywhere).
    private var previous: Character?
    /// A colon at the start of a word was just typed.
    private var colonPending = false
    /// Non-nil while a session is open.
    private var query: String?
    private var matches: [Emoji] = []
    private var selected = 0
    /// An arrow key was pressed in this session. Until then, with a
    /// one-character query, Return and Tab are left to the app: ":D" then
    /// Return should be a new line, not an emoji.
    private var armed = false

    public init() {}

    public var isActive: Bool { query != nil }

    public mutating func type(_ character: Character) -> Outcome {
        defer { previous = character }

        if let query {
            guard Self.continuesQuery(character) else {
                end()
                return .end
            }
            self.query = query + String(character)
            return refresh()
        }

        if colonPending {
            colonPending = false
            if character.isLetter || character.isNumber {
                query = String(character)
                selected = 0
                armed = false
                return refresh()
            }
            return .none
        }

        if character == ":", Self.isWordStart(previous) {
            colonPending = true
        }
        return .none
    }

    /// The user pressed delete (and it was not undoing an expansion).
    public mutating func backspace() -> Outcome {
        // What was before the deleted character is unknown here; treating it
        // as mid-word is the safe side.
        previous = "x"
        colonPending = false
        guard let query else { return .none }
        guard query.count > 1 else {
            end()
            return .end
        }
        self.query = String(query.dropLast())
        return refresh()
    }

    /// One of the popup's keys. `popupVisible` is whether the popup is on
    /// screen right now; until it is, every key goes to the app.
    public mutating func press(_ key: Key, popupVisible: Bool) -> (outcome: Outcome, swallow: Bool) {
        guard let query else { return (.none, false) }
        let usable = popupVisible && !matches.isEmpty

        switch key {
        case .up, .down:
            guard usable else { return (.none, false) }
            armed = true
            let step = key == .down ? 1 : -1
            selected = (selected + step + matches.count) % matches.count
            return (.show(matches: matches, selected: selected), true)
        case .enter, .tab:
            guard usable, query.count >= 2 || armed else {
                end()
                return (.end, false)
            }
            return (insert(at: selected), true)
        case .escape:
            end()
            return (.end, usable)
        }
    }

    /// A click on a row of the popup.
    public mutating func choose(index: Int) -> Outcome {
        guard isActive, matches.indices.contains(index) else { return .none }
        return insert(at: index)
    }

    /// The caret may have moved: forget everything.
    public mutating func reset() -> Outcome {
        let wasActive = isActive
        end()
        previous = nil
        return wasActive ? .end : .none
    }

    private mutating func refresh() -> Outcome {
        matches = EmojiCatalog.search(query ?? "", recents: recents)
        selected = min(selected, max(matches.count - 1, 0))
        return .show(matches: matches, selected: selected)
    }

    private mutating func insert(at index: Int) -> Outcome {
        let emoji = matches[index]
        let typed = ":" + (query ?? "")
        end()
        // The inserted emoji is not a word character: a colon straight after
        // it may start another session.
        previous = " "
        return .insert(Expansion(deleteCount: typed.count, text: emoji.character), emoji: emoji, typed: typed)
    }

    private mutating func end() {
        query = nil
        colonPending = false
        matches = []
        selected = 0
        armed = false
    }

    private static func continuesQuery(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// A colon after one of these starts a word.
    private static func isWordStart(_ previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous.isWhitespace || "([{\"'“‘«".contains(previous)
    }
}
