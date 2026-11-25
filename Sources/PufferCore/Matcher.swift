import Foundation

/// What the engine must do to the focused text field: delete some characters
/// that are already there, then insert some text. Used both to expand a
/// shortcode and to undo an expansion.
public struct Expansion: Equatable, Sendable {
    /// Number of characters to delete. The key that fired this (the trigger
    /// key, the shortcode's last character, or the undo backspace) is
    /// swallowed before it reaches the app, so it is never counted.
    public let deleteCount: Int
    /// Text to insert afterwards.
    public let text: String

    public init(deleteCount: Int, text: String) {
        self.deleteCount = deleteCount
        self.text = text
    }
}

/// Keeps a rolling buffer of typed characters and reports when it ends in a
/// shortcode that should expand. Also remembers the last expansion so that
/// pressing delete straight afterwards can undo it.
public struct Matcher: Sendable {
    public static let maxBufferLength = 128

    /// Undoing an expansion takes one backspace per character it inserted,
    /// a couple of milliseconds each. Past this length that is slow enough
    /// to look like a hang, so delete just deletes.
    public static let maxUndoLength = 300

    private struct Candidate: Sendable {
        let code: [Character]
        /// nil = expands immediately, with no trigger key.
        let trigger: Character?
        let keepsTrigger: Bool
        let text: String
    }

    private struct Undo: Sendable {
        /// How many characters the expansion put into the document.
        let insertedCount: Int
        /// What the user had typed: the shortcode plus any trigger key.
        let typed: String
    }

    private var buffer: [Character] = []
    private var candidates: [Candidate] = []
    private var undo: Undo?

    public init(entries: [Entry] = []) {
        setEntries(entries)
    }

    public var bufferContents: String { String(buffer) }

    public mutating func setEntries(_ entries: [Entry]) {
        candidates = entries
            .filter { !$0.shortcode.isEmpty && !$0.text.isEmpty }
            .map {
                Candidate(
                    code: Array($0.shortcode),
                    trigger: $0.trigger.character,
                    // A trigger period is always dropped.
                    keepsTrigger: $0.trigger == .space && $0.keepsTrigger,
                    text: $0.text
                )
            }
            // Longest shortcode wins when several match. Between equal
            // lengths the entry that comes first in the library wins; the
            // position is compared explicitly because `sorted` does not
            // promise to keep equal elements in order.
            .enumerated()
            .sorted { ($1.element.code.count, $0.offset) < ($0.element.code.count, $1.offset) }
            .map(\.element)
    }

    /// The caret may have moved: forget what was typed, and any pending undo.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        undo = nil
    }

    /// The user pressed delete. Straight after an expansion this returns the
    /// edit that puts the shortcode back; otherwise it drops the last typed
    /// character and returns nil.
    public mutating func backspace() -> Expansion? {
        if let undo {
            reset()
            return Expansion(deleteCount: undo.insertedCount, text: undo.typed)
        }
        if !buffer.isEmpty { buffer.removeLast() }
        return nil
    }

    /// Feed one typed character. Returns an expansion when it completes one.
    public mutating func type(_ character: Character) -> Expansion? {
        undo = nil

        // Shortcode already in the buffer, and this is its trigger key.
        if let match = candidates.first(where: { $0.trigger == character && bufferEnds(with: $0.code) }) {
            let inserted = match.keepsTrigger ? match.text + String(character) : match.text
            reset()
            rememberForUndo(inserted: inserted, typed: String(match.code) + String(character))
            return Expansion(deleteCount: match.code.count, text: inserted)
        }

        buffer.append(character)
        if buffer.count > Self.maxBufferLength {
            buffer.removeFirst(buffer.count - Self.maxBufferLength)
        }

        // This character completes a shortcode that expands immediately.
        // Its last character never reaches the app, hence count - 1.
        if let match = candidates.first(where: { $0.trigger == nil && bufferEnds(with: $0.code) }) {
            reset()
            rememberForUndo(inserted: match.text, typed: String(match.code))
            return Expansion(deleteCount: match.code.count - 1, text: match.text)
        }
        return nil
    }

    /// Something other than a shortcode replaced `typed` with `inserted`
    /// (an emoji picked from the popup): treat it like an expansion, so
    /// delete straight afterwards puts `typed` back.
    public mutating func remember(inserted: String, typed: String) {
        reset()
        rememberForUndo(inserted: inserted, typed: typed)
    }

    private mutating func rememberForUndo(inserted: String, typed: String) {
        let count = inserted.count
        undo = count <= Self.maxUndoLength ? Undo(insertedCount: count, typed: typed) : nil
    }

    private func bufferEnds(with code: [Character]) -> Bool {
        guard buffer.count >= code.count, buffer.suffix(code.count).elementsEqual(code) else {
            return false
        }
        // A shortcode that starts with a letter or digit must start a word,
        // so "sig" does not fire inside "design". Shortcodes that start with
        // punctuation (";sig") can follow anything.
        guard let first = code.first, first.isLetter || first.isNumber else { return true }
        let precedingIndex = buffer.count - code.count - 1
        guard precedingIndex >= 0 else { return true }
        let preceding = buffer[precedingIndex]
        return !(preceding.isLetter || preceding.isNumber)
    }
}
