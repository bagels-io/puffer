import Foundation
import Testing
@testable import PufferCore

private func characters(_ emoji: [Emoji]) -> [String] {
    emoji.map(\.character)
}

@Suite struct EmojiCatalogTests {
    @Test func allHaveNamesAndCuratedHaveAtMostThreeAliases() {
        #expect(EmojiCatalog.all.count > 1500)
        #expect(Set(EmojiCatalog.all.map(\.character)).count == EmojiCatalog.all.count)
        for emoji in EmojiCatalog.all {
            #expect(!emoji.name.isEmpty)
            #expect(emoji.name == emoji.name.lowercased())
        }
        for emoji in EmojiCatalog.curated {
            #expect(emoji.aliases.count <= 3, "\(emoji.character)")
        }
    }

    @Test func curatedComeFirstAndGainKeywords() {
        #expect(Array(EmojiCatalog.all.prefix(EmojiCatalog.curated.count)).map(\.character)
            == EmojiCatalog.curated.map(\.character))
        let party = EmojiCatalog.all.first { $0.character == "🎉" }!
        #expect(party.aliases.starts(with: ["party", "celebration", "confetti"]))
        #expect(party.aliases.contains("tada"))
    }

    @Test func everyCuratedEmojiIsStandard() {
        let standard = Set(EmojiDataTests.parsed.map { $0.character.filter { $0 != "\u{FE0F}" } })
        for emoji in EmojiCatalog.curated {
            #expect(standard.contains(emoji.character.filter { $0 != "\u{FE0F}" }), "\(emoji.character)")
        }
    }

    @Test func findsEmojiOutsideTheCuratedList() {
        let trees = characters(EmojiCatalog.search("tree"))
        for tree in ["🌲", "🌳", "🎄", "🌴"] {
            #expect(trees.contains(tree), "\(tree) in \(trees)")
        }
        #expect(characters(EmojiCatalog.search("forest")).contains("🌳"))
        #expect(characters(EmojiCatalog.search("japan")).prefix(2).contains("🇯🇵"))
        #expect(characters(EmojiCatalog.search("here")).contains("🈁"))
    }

    @Test func addedKeywordsDoNotLiftEverydayEmoji() {
        // 😘 has Unicode's keyword "heart", but is not a heart emoji.
        #expect(!characters(EmojiCatalog.search("heart")).contains("😘"))
        // Still found by a keyword alone.
        #expect(characters(EmojiCatalog.search("tada")).first == "🎉")
    }

    @Test func curatedBeatGenerated() {
        #expect(EmojiCatalog.search("pop").first?.character == "🎉")   // not 🍿
        #expect(EmojiCatalog.search("heart").first?.character == "❤️")  // not ♥️
    }

    @Test func nameBeatsKeyword() {
        #expect(EmojiCatalog.search("cat").first?.character == "🐈")
        #expect(EmojiCatalog.search("house").first?.character == "🏠")
        #expect(["🐕", "🐶"].contains(EmojiCatalog.search("dog").first?.character))
        #expect(EmojiCatalog.search("star").first?.character == "⭐")
    }

    @Test func recentsBeatCurated() {
        #expect(EmojiCatalog.search("p", recents: ["🍿"]).first?.character == "🍿")
    }

    @Test func searchIsQuick() {
        let start = Date()
        for query in ["a", "s", "he", "tree", "japan", "qqq", "p", "cat", "smi", "fl"] {
            for _ in 0..<10 { _ = EmojiCatalog.search(query) }
        }
        #expect(Date().timeIntervalSince(start) < 2)  // debug build, shared CI machines
    }

    @Test func matchesStartOfAnyWord() {
        #expect(EmojiCatalog.search("pop").first?.character == "🎉")
        #expect(Array(characters(EmojiCatalog.search("par")).prefix(2)) == ["🎉", "🥳"])
    }

    @Test func aliasMatches() {
        #expect(EmojiCatalog.search("celeb").first?.character == "🎉")
        #expect(EmojiCatalog.search("100").first?.character == "💯")
    }

    @Test func caseInsensitive() {
        #expect(EmojiCatalog.search("PARTY") == EmojiCatalog.search("party"))
    }

    @Test func noMidWordMatch() {
        #expect(!EmojiCatalog.search("arty").contains { $0.character == "🎉" })
    }

    @Test func groupsInOrder() {
        // Whole word, then name start, then alias start, then a later word.
        #expect(Array(characters(EmojiCatalog.search("heart")).prefix(3)) == ["❤️", "😍", "💜"])
    }

    @Test func recentsFirst() {
        #expect(EmojiCatalog.search("p", recents: ["🙏"]).first?.character == "🙏")
        #expect(EmojiCatalog.search("qqq", recents: ["🎂"]).isEmpty)
    }

    @Test func limitsToSix() {
        #expect(EmojiCatalog.search("s").count == EmojiCatalog.maxResults)
        #expect(EmojiCatalog.maxResults == 6)
        #expect(EmojiCatalog.search("qqqq").isEmpty)
        #expect(EmojiCatalog.search("").isEmpty)
    }
}

private func emoji(_ character: String) -> Emoji {
    EmojiCatalog.all.first { $0.character == character }!
}

/// Types `text` into the session and returns every outcome.
@discardableResult
private func feed(_ session: inout EmojiSession, _ text: String) -> [EmojiSession.Outcome] {
    text.map { session.type($0) }
}

private func showsAnything(_ outcomes: [EmojiSession.Outcome]) -> Bool {
    outcomes.contains {
        if case .show(let matches, _) = $0 { return !matches.isEmpty }
        return false
    }
}

private func firstMatch(_ outcome: EmojiSession.Outcome?) -> String? {
    if case .show(let matches, _) = outcome { return matches.first?.character }
    return nil
}

private func selection(_ outcome: EmojiSession.Outcome) -> Int? {
    if case .show(_, let selected) = outcome { return selected }
    return nil
}

@Suite struct EmojiSessionTests {
    @Test func opensOnColonAndLetter() {
        var session = EmojiSession()
        let outcome = feed(&session, ":p").last
        #expect(firstMatch(outcome) == "🎉")
        #expect(selection(outcome!) == 0)
        #expect(session.isActive)
    }

    @Test func colonAloneShowsNothing() {
        var session = EmojiSession()
        #expect(feed(&session, ":") == [.none])
        #expect(!session.isActive)
    }

    @Test func opensAfterSpaceAndBrackets() {
        for text in ["hi :p", "(:p", "\":p", "“:p"] {
            var session = EmojiSession()
            #expect(firstMatch(feed(&session, text).last) == "🎉", "\(text)")
        }
    }

    @Test func doesNotOpenMidWord() {
        for text in ["a:p", "10:30", "https://x", "a::b", "x:-)", ":)", ":-)"] {
            var session = EmojiSession()
            #expect(!showsAnything(feed(&session, text)), "\(text)")
            #expect(!session.isActive, "\(text)")
        }
    }

    @Test func digitsOpen() {
        var session = EmojiSession()
        #expect(firstMatch(feed(&session, ":100").last) == "💯")

        var other = EmojiSession()
        feed(&other, ":3")
        #expect(other.isActive)
    }

    @Test func queryExtendsAndNarrows() {
        var session = EmojiSession()
        #expect(firstMatch(feed(&session, ":part").last) == "🎉")
        var dashed = EmojiSession()
        #expect(firstMatch(feed(&dashed, ":see-no").last) == "🙈")
        var underscored = EmojiSession()
        feed(&underscored, ":thumbs_")
        #expect(underscored.isActive)
    }

    @Test func spaceEnds() {
        var session = EmojiSession()
        #expect(feed(&session, ":par ").last == .end)
        #expect(!session.isActive)
    }

    @Test func noMatchesKeepsSession() {
        var session = EmojiSession()
        #expect(feed(&session, ":partyy").last == .show(matches: [], selected: 0))
        #expect(session.isActive)
        #expect(firstMatch(session.backspace()) == "🎉")
    }

    @Test func backspaceOverFirstLetterEnds() {
        var session = EmojiSession()
        feed(&session, ":p")
        #expect(session.backspace() == .end)
        #expect(!session.isActive)
    }

    @Test func arrowsMoveAndWrap() {
        var session = EmojiSession()
        feed(&session, ":par")
        let down = session.press(.down, popupVisible: true)
        #expect(selection(down.outcome) == 1)
        #expect(down.swallow)
        _ = session.press(.up, popupVisible: true)
        let wrapped = session.press(.up, popupVisible: true)
        guard case .show(let matches, let selected) = wrapped.outcome else {
            Issue.record("expected show")
            return
        }
        #expect(selected == matches.count - 1)
    }

    @Test func enterInsertsFromTwoLetters() {
        var session = EmojiSession()
        feed(&session, ":pa")
        let result = session.press(.enter, popupVisible: true)
        #expect(result.outcome == .insert(Expansion(deleteCount: 3, text: "🎉"), emoji: emoji("🎉"), typed: ":pa"))
        #expect(result.swallow)
        #expect(!session.isActive)
    }

    @Test func tabInserts() {
        var session = EmojiSession()
        feed(&session, ":pa")
        let result = session.press(.tab, popupVisible: true)
        #expect(result.outcome == .insert(Expansion(deleteCount: 3, text: "🎉"), emoji: emoji("🎉"), typed: ":pa"))
        #expect(result.swallow)
    }

    @Test func oneLetterEnterPassesThrough() {
        var session = EmojiSession()
        feed(&session, ":d")
        let result = session.press(.enter, popupVisible: true)
        #expect(result.outcome == .end)
        #expect(!result.swallow)
        #expect(!session.isActive)
    }

    @Test func oneLetterEnterAfterArrowInserts() {
        var session = EmojiSession()
        feed(&session, ":d")
        _ = session.press(.down, popupVisible: true)
        let result = session.press(.enter, popupVisible: true)
        guard case .insert(let expansion, _, let typed) = result.outcome else {
            Issue.record("expected insert")
            return
        }
        #expect(expansion.deleteCount == 2)
        #expect(typed == ":d")
        #expect(result.swallow)
    }

    @Test func keysPassWhenPopupNotVisible() {
        var session = EmojiSession()
        feed(&session, ":pa")
        let arrow = session.press(.down, popupVisible: false)
        #expect(!arrow.swallow)
        #expect(session.isActive)
        let enter = session.press(.enter, popupVisible: false)
        #expect(!enter.swallow)
        #expect(enter.outcome == .end)
    }

    @Test func keysPassWithNoMatches() {
        var session = EmojiSession()
        feed(&session, ":qqq")
        let result = session.press(.enter, popupVisible: true)
        #expect(!result.swallow)
        #expect(result.outcome == .end)
    }

    @Test func escapeEnds() {
        var session = EmojiSession()
        feed(&session, ":pa")
        let result = session.press(.escape, popupVisible: true)
        #expect(result.outcome == .end)
        #expect(result.swallow)
    }

    @Test func chooseInserts() {
        var session = EmojiSession()
        feed(&session, ":par")
        #expect(session.choose(index: 1) == .insert(Expansion(deleteCount: 4, text: "🥳"), emoji: emoji("🥳"), typed: ":par"))
        #expect(!session.isActive)
    }

    @Test func resetEnds() {
        var session = EmojiSession()
        #expect(session.reset() == .none)
        feed(&session, "a")
        feed(&session, ":p")
        #expect(session.isActive == false)
        #expect(session.reset() == .none)
        // After a reset the next character is at the start of the text.
        #expect(firstMatch(feed(&session, ":p").last) == "🎉")
        #expect(session.reset() == .end)
    }

    @Test func recentsComeFirst() {
        var session = EmojiSession()
        session.recents = ["🙏"]
        #expect(firstMatch(feed(&session, ":p").last) == "🙏")
    }
}

@Suite struct MatcherRememberTests {
    @Test func rememberedEmojiUndoes() {
        var matcher = Matcher()
        matcher.remember(inserted: "🎉", typed: ":pa")
        #expect(matcher.backspace() == Expansion(deleteCount: 1, text: ":pa"))
    }
}

@Suite struct CaretGeometryTests {
    let mimestreamBody = CGRect(x: 760, y: 288, width: 769, height: 709)
    let gmailBody = CGRect(x: 423, y: 351, width: 1028, height: 544)
    let junk = CGRect(x: 0, y: 1112, width: 0, height: 0)

    @Test func usesRangeBoundsWhenValid() {
        let caret = CaretGeometry.caret(
            rangeBounds: CGRect(x: 790, y: 288, width: 2, height: 15),
            markerBounds: nil, element: mimestreamBody, location: 5)
        #expect(caret == CGRect(x: 790, y: 288, width: 2, height: 15))
    }

    @Test func rejectsZeroHeightJunk() {
        let caret = CaretGeometry.caret(
            rangeBounds: junk, markerBounds: CGRect(x: 449, y: 353, width: 0, height: 15),
            element: gmailBody, location: 4)
        #expect(caret == CGRect(x: 449, y: 353, width: 0, height: 15))
    }

    @Test func lineRectUsesLeftEdge() {
        let caret = CaretGeometry.caret(
            rangeBounds: junk, markerBounds: CGRect(x: 423, y: 371, width: 1028, height: 19),
            element: gmailBody, location: 7)
        #expect(caret == CGRect(x: 423, y: 371, width: 0, height: 19))
    }

    @Test func mimestreamLineStartQuirk() {
        let atLineStart = CaretGeometry.caret(
            rangeBounds: CGRect(x: 1527, y: 304, width: 2, height: 16),
            markerBounds: nil, element: mimestreamBody, location: 8)
        #expect(atLineStart == CGRect(x: 760, y: 304, width: 2, height: 16))
    }

    @Test func outsideElementIsRejected() {
        let field = CGRect(x: 415, y: 55, width: 631, height: 24)
        let caret = CaretGeometry.caret(
            rangeBounds: junk, markerBounds: CGRect(x: 257, y: 181, width: 0, height: 0),
            element: field, location: 3)
        #expect(caret == CGRect(x: 415, y: 55, width: 0, height: 24))
    }

    @Test func nothingKnown() {
        #expect(CaretGeometry.caret(rangeBounds: nil, markerBounds: nil, element: nil, location: 0) == nil)
    }
}

@Suite struct EmojiAppsTests {
    @Test func offInTerminalsEditorsAndAppsWithTheirOwnPicker() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                   "com.microsoft.VSCode", "com.apple.dt.Xcode", "dev.zed.Zed",
                   "com.jetbrains.intellij", "com.tinyspeck.slackmacgap", "com.hnc.Discord"] {
            #expect(!EmojiApps.suggestionsAllowed(in: id), "\(id)")
        }
    }

    @Test func onEverywhereElse() {
        for id in ["com.google.Chrome", "com.mimestream.Mimestream", "com.apple.TextEdit", "com.apple.mail"] {
            #expect(EmojiApps.suggestionsAllowed(in: id), "\(id)")
        }
        #expect(EmojiApps.suggestionsAllowed(in: nil))
    }
}

@Suite struct EmojiDataTests {
    static let parsed = EmojiCatalog.parse(EmojiCatalog.data)

    private func find(_ character: String) -> Emoji? {
        Self.parsed.first { $0.character == character }
    }

    @Test func coversTheStandardSet() {
        #expect(Self.parsed.count > 1500)
        #expect(Set(Self.parsed.map(\.character)).count == Self.parsed.count)
    }

    @Test func namesAndKeywords() {
        let tree = find("🌳")
        #expect(tree?.name == "deciduous tree")
        #expect(tree?.aliases.contains("forest") == true)
        #expect(find("🇯🇵")?.name.contains("japan") == true)
        #expect(find("❤️‍🔥") != nil)
        #expect(find("🧑‍💻") != nil)
    }

    @Test func noSkinTonesOrNewerThanEmoji15() {
        let tones: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
        #expect(!Self.parsed.contains { $0.character.unicodeScalars.contains { tones.contains($0.value) } })
        #expect(find("🫨") != nil)   // shaking face, Emoji 15.0
        #expect(find("🫩") == nil)   // face with bags under eyes, Emoji 16.0
    }

    @Test func lowerCaseAndNoRepeatedNameWords() {
        for emoji in Self.parsed {
            #expect(emoji.name == emoji.name.lowercased(), "\(emoji.character)")
            let nameWords = Set(emoji.name.split(separator: " ").map(String.init))
            for alias in emoji.aliases {
                #expect(alias == alias.lowercased(), "\(emoji.character) \(alias)")
                #expect(!nameWords.contains(alias), "\(emoji.character) \(alias)")
            }
        }
    }

    @Test func parsesQuickly() {
        let start = Date()
        for _ in 0..<10 { _ = EmojiCatalog.parse(EmojiCatalog.data) }
        #expect(Date().timeIntervalSince(start) < 2)  // debug build, shared CI machines
    }
}
