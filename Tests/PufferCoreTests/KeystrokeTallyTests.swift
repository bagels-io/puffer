import Foundation
import Testing
@testable import PufferCore

@Suite struct KeystrokeTallyTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let us = Locale(identifier: "en_US")

    @Test func savingIsInsertedMinusTyped() {
        // ";sig" + space → 20 characters: typed 4 deleted + 1 swallowed.
        #expect(KeystrokeTally.saving(of: Expansion(deleteCount: 4, text: String(repeating: "x", count: 20))) == 15)
        // Immediate ";e" → 9 characters: 1 deleted + 1 swallowed.
        #expect(KeystrokeTally.saving(of: Expansion(deleteCount: 1, text: "hi@me.com")) == 7)
        // Longer shortcode than text: nothing saved, never negative.
        #expect(KeystrokeTally.saving(of: Expansion(deleteCount: 5, text: "ok")) == 0)
        // Emoji: ":tree" ⏎ (5 deleted + 1 swallowed) for one character.
        #expect(KeystrokeTally.saving(of: Expansion(deleteCount: 5, text: "🌳")) == 0)
    }

    @Test func undoTakesItBack() {
        var tally = KeystrokeTally()
        tally.expanded(Expansion(deleteCount: 4, text: String(repeating: "x", count: 20)), at: start)
        #expect(tally.total == 15)
        // The undo deletes the 20 inserted and types the 5 back.
        tally.undid(Expansion(deleteCount: 20, text: ";sig "))
        #expect(tally.total == 0)
        // An emoji undo takes nothing back.
        tally.expanded(Expansion(deleteCount: 1, text: "hello"), at: start)
        tally.undid(Expansion(deleteCount: 1, text: ":tree"))
        #expect(tally.total == 3)
    }

    @Test func neverBelowZero() {
        var tally = KeystrokeTally()
        tally.undid(Expansion(deleteCount: 50, text: "x"))
        #expect(tally.total == 0)
    }

    @Test func milestoneFiresOnce() {
        var tally = KeystrokeTally(total: 990)
        let big = Expansion(deleteCount: 1, text: String(repeating: "x", count: 22)) // saves 20
        #expect(tally.expanded(big, at: start) == 1_000)
        #expect(tally.reached == 1_000)
        tally.undid(Expansion(deleteCount: 22, text: "ab"))
        #expect(tally.total == 990)
        #expect(tally.expanded(big, at: start) == nil)
        #expect(tally.expanded(Expansion(deleteCount: 0, text: "x"), at: start) == nil)
    }

    @Test func jumpingPastSeveralReportsTheHighest() {
        var tally = KeystrokeTally(total: 999)
        let huge = Expansion(deleteCount: 1, text: String(repeating: "x", count: 10_002))
        #expect(tally.expanded(huge, at: start) == 10_000)
        #expect(tally.reached == 10_000)
    }

    @Test func menuTitle() {
        #expect(KeystrokeTally().menuTitle(now: start, locale: us) == nil)
        #expect(KeystrokeTally(total: 1).menuTitle(now: start, locale: us) == "Saved 1 keystroke")
        #expect(KeystrokeTally(total: 18_402).menuTitle(now: start, locale: us) == "Saved 18,402 keystrokes")

        var tally = KeystrokeTally(total: 9_990)
        tally.expanded(Expansion(deleteCount: 1, text: String(repeating: "x", count: 226)), at: start)
        #expect(tally.menuTitle(now: start.addingTimeInterval(3_600), locale: us)
            == "🐡 Saved 10,214 keystrokes — past 10,000!")
        #expect(tally.menuTitle(now: start.addingTimeInterval(25 * 3_600), locale: us)
            == "Saved 10,214 keystrokes")
    }

    @Test func noCelebrationAfterUndoingBelowTheMilestone() {
        var tally = KeystrokeTally(total: 990)
        tally.expanded(Expansion(deleteCount: 1, text: String(repeating: "x", count: 22)), at: start)
        tally.undid(Expansion(deleteCount: 22, text: "ab"))
        #expect(tally.menuTitle(now: start, locale: us) == "Saved 990 keystrokes")
    }

    @Test func roundTripsThroughJSON() throws {
        var tally = KeystrokeTally(total: 995)
        tally.expanded(Expansion(deleteCount: 1, text: String(repeating: "x", count: 12)), at: start)
        let data = try JSONEncoder().encode(tally)
        #expect(try JSONDecoder().decode(KeystrokeTally.self, from: data) == tally)
    }
}
