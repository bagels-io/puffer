import Foundation

/// One emoji Puffer can suggest: what it inserts, its name, and a few more
/// words it can be found by.
public struct Emoji: Equatable, Hashable, Sendable {
    public let character: String
    public let name: String
    public let aliases: [String]

    public init(_ character: String, _ name: String, _ aliases: String...) {
        self.character = character
        self.name = name
        self.aliases = aliases
    }
}

/// The fixed list of emoji (`EmojiList.swift`) and the search over it.
public enum EmojiCatalog {
    public static let maxResults = 6

    /// Emoji whose name or an alias has a word starting with `query`, best
    /// first: recently used (most recent first), then those whose name
    /// starts with it, then whose alias starts with it, then a later word.
    /// Within each group, list order.
    public static func search(_ query: String, recents: [String] = []) -> [Emoji] {
        let query = query.lowercased()
        guard !query.isEmpty else { return [] }

        var ranked: [(rank: Int, order: Int, emoji: Emoji)] = []
        for (position, emoji) in all.enumerated() {
            guard let rank = rank(of: emoji, for: query) else { continue }
            if let recent = recents.firstIndex(of: emoji.character) {
                ranked.append((0, recent, emoji))
            } else {
                ranked.append((rank, position, emoji))
            }
        }
        return ranked
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(maxResults)
            .map(\.emoji)
    }

    /// 1: the name starts with the query; 2: an alias does; 3: a later
    /// word of either does; nil: no match.
    private static func rank(of emoji: Emoji, for query: String) -> Int? {
        if emoji.name.hasPrefix(query) { return 1 }
        if emoji.aliases.contains(where: { $0.hasPrefix(query) }) { return 2 }
        let laterWords = ([emoji.name] + emoji.aliases).flatMap { words(in: $0).dropFirst() }
        return laterWords.contains { $0.hasPrefix(query) } ? 3 : nil
    }

    private static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "-" })
    }
}
