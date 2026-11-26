import Foundation

/// One emoji Puffer can suggest: what it inserts, its name, and a few more
/// words it can be found by.
public struct Emoji: Equatable, Hashable, Sendable {
    public let character: String
    public let name: String
    public let aliases: [String]

    public init(_ character: String, _ name: String, _ aliases: String...) {
        self.init(character: character, name: name, aliases: aliases)
    }

    public init(character: String, name: String, aliases: [String]) {
        self.character = character
        self.name = name
        self.aliases = aliases
    }
}

/// Every emoji Puffer knows, and the search over them: the everyday ones
/// (`EmojiList.swift`) first, then the rest of the Unicode standard
/// (`EmojiData.swift`).
public enum EmojiCatalog {
    public static let maxResults = 6

    /// The everyday emoji, with Unicode's keywords added to their own
    /// aliases, then every other standard emoji.
    public static let all: [Emoji] = merge(curated: curated, standard: parse(data))

    /// Emoji whose name or an alias has a word starting with `query`, best
    /// first: recently used (most recent first), then everyday emoji found
    /// by their own name or aliases, then everything else (including
    /// everyday emoji found only by a Unicode keyword). Within each of
    /// those: the name is exactly `query`; a word of the name is; a word of
    /// an alias is; the name starts with it; an alias does; any later word
    /// does. Then list order.
    public static func search(_ query: String, recents: [String] = []) -> [Emoji] {
        let query = query.lowercased()
        guard !query.isEmpty else { return [] }

        var ranked: [(group: Int, rank: Int, order: Int, emoji: Emoji)] = []
        for (position, entry) in index.enumerated() {
            let group: Int
            let rank: Int
            if let found = entry.own.rank(for: query) {
                (group, rank) = (entry.isCurated ? 1 : 2, found)
            } else if let found = entry.extra?.rank(for: query) {
                (group, rank) = (2, found)
            } else {
                continue
            }
            if let recent = recents.firstIndex(of: entry.emoji.character) {
                ranked.append((0, 0, recent, entry.emoji))
            } else {
                ranked.append((group, rank, position, entry.emoji))
            }
        }
        return ranked
            .sorted { ($0.group, $0.rank, $0.order) < ($1.group, $1.rank, $1.order) }
            .prefix(maxResults)
            .map(\.emoji)
    }

    /// Text to match a query against, split into words once rather than on
    /// every keystroke.
    private struct Searchable {
        let name: String?
        let aliases: [String]
        let nameWords: Set<String>
        let aliasWords: Set<String>
        let laterWords: [String]

        init(name: String?, aliases: [String]) {
            self.name = name
            self.aliases = aliases
            let split = { (text: String) in EmojiCatalog.words(in: text).map(String.init) }
            let nameSplit = name.map(split) ?? []
            let aliasSplit = aliases.map(split)
            nameWords = Set(nameSplit)
            aliasWords = Set(aliasSplit.joined())
            laterWords = ([nameSplit] + aliasSplit).flatMap { $0.dropFirst() }
        }

        /// 0: the name is the query; 1: a word of the name is; 2: a word of
        /// an alias is; 3: the name starts with it; 4: an alias does; 5: a
        /// later word of either does; nil: no match. Whole words first, so
        /// `:japan` finds 🇯🇵 among the "japanese …" emoji, and the name
        /// before aliases, so `:cat` finds 🐈 before every cat-face smiley.
        func rank(for query: String) -> Int? {
            if name == query { return 0 }
            if nameWords.contains(query) { return 1 }
            if aliasWords.contains(query) { return 2 }
            if name?.hasPrefix(query) == true { return 3 }
            if aliases.contains(where: { $0.hasPrefix(query) }) { return 4 }
            return laterWords.contains { $0.hasPrefix(query) } ? 5 : nil
        }
    }

    private struct Entry {
        let emoji: Emoji
        let isCurated: Bool
        /// The name and the aliases written for Puffer (or, outside the
        /// everyday list, Unicode's keywords).
        let own: Searchable
        /// An everyday emoji's added Unicode keywords. They find it, but
        /// do not lift it above the rest.
        let extra: Searchable?
    }

    private static let index: [Entry] = all.enumerated().map { position, emoji in
        guard position < curated.count else {
            return Entry(emoji: emoji, isCurated: false, own: Searchable(name: emoji.name, aliases: emoji.aliases), extra: nil)
        }
        let ownCount = curated[position].aliases.count
        return Entry(
            emoji: emoji,
            isCurated: true,
            own: Searchable(name: emoji.name, aliases: Array(emoji.aliases.prefix(ownCount))),
            extra: Searchable(name: nil, aliases: Array(emoji.aliases.dropFirst(ownCount)))
        )
    }

    /// The everyday emoji in their own order, each gaining the standard
    /// list's keywords, then the standard emoji that are not among them.
    static func merge(curated: [Emoji], standard: [Emoji]) -> [Emoji] {
        let standardByKey = Dictionary(standard.map { (key($0.character), $0) }, uniquingKeysWith: { first, _ in first })
        let curatedKeys = Set(curated.map { key($0.character) })
        let enriched = curated.map { emoji -> Emoji in
            guard let match = standardByKey[key(emoji.character)] else { return emoji }
            let nameWords = Set(words(in: emoji.name))
            let extra = match.aliases.filter { !emoji.aliases.contains($0) && !nameWords.contains(Substring($0)) }
            return Emoji(character: emoji.character, name: emoji.name, aliases: emoji.aliases + extra)
        }
        return enriched + standard.filter { !curatedKeys.contains(key($0.character)) }
    }

    /// The same emoji with or without U+FE0F (the emoji presentation
    /// selector) is the same emoji.
    private static func key(_ character: String) -> String {
        String(String.UnicodeScalarView(character.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    /// Reads `data` (`EmojiData.swift`): a line per emoji, tab-separated
    /// character, name and "|"-separated keywords.
    static func parse(_ data: String) -> [Emoji] {
        data.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return Emoji(
                character: String(fields[0]),
                name: String(fields[1]),
                aliases: fields[2].split(separator: "|").map(String.init)
            )
        }
    }

    /// Words are runs of letters and digits: "flag: japan" has "japan",
    /// and "japanese “here” button" has "here".
    fileprivate static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }
}
