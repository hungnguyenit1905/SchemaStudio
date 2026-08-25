//
//  DuplicateTargetNamingTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("DuplicateTargetNaming")
struct DuplicateTargetNamingTests {
    private let postgres = TransferIdentifierPolicy.policy(for: .postgresql)

    @Test("A free name gets the plain _copy suffix")
    func plainSuffix() {
        #expect(DuplicateTargetNaming.suggestedName(source: "orders", taken: [], policy: postgres) == "orders_copy")
    }

    /// The namespace check is deliberately kind-blind: a table name collides with a view, a
    /// sequence or an index in the same schema.
    @Test("Taken names are skipped in order until one is free")
    func numberedSuffixes() {
        let taken: Set<String> = ["orders_copy", "orders_copy1", "orders_copy2"]
        #expect(
            DuplicateTargetNaming.suggestedName(source: "orders", taken: taken, policy: postgres)
                == "orders_copy3"
        )
    }

    @Test("An empty name is rejected")
    func emptyNameRejected() {
        #expect(DuplicateTargetNaming.validate("", policy: postgres) == .empty)
        #expect(DuplicateTargetNaming.validate("   ", policy: postgres) == .empty)
    }

    @Test("A name inside the byte budget is accepted")
    func shortNameAccepted() {
        #expect(DuplicateTargetNaming.validate("orders_copy", policy: postgres) == nil)
    }

    /// 63 bytes, not 63 characters. A Vietnamese name with diacritics spends two or three bytes
    /// per character, so it runs out of room at roughly a third of the character count.
    @Test("The limit counts bytes, so a diacritic name is refused earlier than its length suggests")
    func byteLimitNotCharacterLimit() {
        let name = String(repeating: "đ", count: 40)
        #expect(name.count == 40)
        #expect(name.utf8.count > 63)
        #expect(DuplicateTargetNaming.validate(name, policy: postgres) == .tooLongForVendor(limitBytes: 63))

        let asciiSameLength = String(repeating: "a", count: 40)
        #expect(DuplicateTargetNaming.validate(asciiSameLength, policy: postgres) == nil)
    }

    /// A suggestion must never exceed the limit, so a source already near the budget gets a
    /// shortened name with a stable hash rather than a name the server will reject.
    @Test("A suggestion for an over-long source stays inside the byte budget")
    func suggestionRespectsByteBudget() {
        let source = String(repeating: "b", count: 62)
        let suggestion = DuplicateTargetNaming.suggestedName(source: source, taken: [], policy: postgres)
        #expect(suggestion.utf8.count <= 63)
        #expect(DuplicateTargetNaming.validate(suggestion, policy: postgres) == nil)
    }

    @Test("A shortened suggestion is stable across runs")
    func suggestionIsStable() {
        let source = String(repeating: "c", count: 70)
        let first = DuplicateTargetNaming.suggestedName(source: source, taken: [], policy: postgres)
        let second = DuplicateTargetNaming.suggestedName(source: source, taken: [], policy: postgres)
        #expect(first == second)
    }

    @Test("A shortened suggestion still avoids a taken name")
    func shortenedSuggestionAvoidsCollision() {
        let source = String(repeating: "d", count: 62)
        let base = DuplicateTargetNaming.suggestedName(source: source, taken: [], policy: postgres)
        let next = DuplicateTargetNaming.suggestedName(source: source, taken: [base], policy: postgres)
        #expect(next != base)
        #expect(next.utf8.count <= 63)
    }
}
