//
//  TextGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Text generators")
struct TextGeneratorTests {
    private static let registry = GeneratorRegistry.standard

    private func generator(
        _ identifier: String,
        params: String = "{}",
        dataType: String = "text",
        columnName: String = "value"
    ) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(name: columnName, dataType: dataType),
            seed: 21
        )
    }

    private func texts(
        _ generator: any ValueGenerator,
        count: Int,
        row: @autoclosure () -> RowContext = GeneratorTestFixtures.rowContext()
    ) throws -> [String] {
        try (0..<count).map { index in
            let value = try generator.next(row: row(), index: index)
            guard case let .text(text) = value else {
                Issue.record("\(type(of: generator)) produced \(value) rather than text")
                return ""
            }
            return text
        }
    }

    // MARK: - Lorem

    @Test("A sentence starts with a capital and ends with a full stop")
    func sentenceShape() throws {
        let sentences = try texts(
            generator(LoremSentenceGenerator.identifier, params: #"{"minWords":4,"maxWords":9}"#),
            count: 200
        )
        for sentence in sentences {
            #expect(sentence.hasSuffix("."))
            #expect(sentence.first?.isUppercase == true)
            let words = sentence.dropLast().split(separator: " ")
            #expect((4...9).contains(words.count))
        }
    }

    @Test("A paragraph holds the requested number of sentences")
    func paragraphSentenceCount() throws {
        let paragraphs = try texts(
            generator(LoremParagraphGenerator.identifier, params: #"{"minSentences":2,"maxSentences":4}"#),
            count: 200
        )
        for paragraph in paragraphs {
            let sentences = paragraph.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect((2...4).contains(sentences.count))
        }
    }

    @Test("Text separates its paragraphs with a blank line")
    func textParagraphCount() throws {
        let blocks = try texts(
            generator(LoremTextGenerator.identifier, params: #"{"minParagraphs":2,"maxParagraphs":3}"#),
            count: 100
        )
        for block in blocks {
            let paragraphs = block.components(separatedBy: "\n\n")
            #expect((2...3).contains(paragraphs.count))
            #expect(paragraphs.allSatisfy { $0.hasSuffix(".") })
        }
    }

    /// A maximum below the minimum is a configuration mistake that used to trap
    /// on an invalid `ClosedRange` rather than being clamped.
    @Test("An inverted word range is clamped rather than trapping")
    func invertedRangesAreClamped() throws {
        let sentence = try texts(
            generator(LoremSentenceGenerator.identifier, params: #"{"minWords":9,"maxWords":2}"#),
            count: 20
        )
        #expect(sentence.allSatisfy { $0.dropLast().split(separator: " ").count == 2 })

        let paragraph = try texts(
            generator(LoremParagraphGenerator.identifier, params: #"{"minSentences":0,"maxSentences":0}"#),
            count: 20
        )
        #expect(paragraph.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Slug

    @Test("A slug folds diacritics, including the Vietnamese d with a bar")
    func slugFoldsDiacritics() throws {
        let slug = try generator(SlugGenerator.identifier, params: #"{"sourceColumn":"title"}"#)
        let row = RowContext(table: "t", rowIndex: 0, values: ["title": .text("Đèn bàn LED Hưng Thịnh")])
        let value = try slug.next(row: row, index: 0)
        #expect(value == .text("den-ban-led-hung-thinh"))
    }

    @Test("A slug honours its separator and word limit")
    func slugRespectsParameters() throws {
        let slug = try generator(
            SlugGenerator.identifier,
            params: #"{"sourceColumn":"title","separator":"_","maxWords":2}"#
        )
        let row = RowContext(table: "t", rowIndex: 0, values: ["title": .text("Wireless Desk Lamp Pro")])
        #expect(try slug.next(row: row, index: 0) == .text("wireless_desk"))
    }

    @Test("A slug reads a non-text source through the same rendering the driver would")
    func slugRendersNonTextSources() throws {
        let slug = try generator(SlugGenerator.identifier, params: #"{"sourceColumn":"title"}"#)
        let row = RowContext(table: "t", rowIndex: 0, values: ["title": .int(4_207)])
        #expect(try slug.next(row: row, index: 0) == .text("4207"))
    }

    @Test("A slug fits the column it is written into")
    func slugTruncatesToTheColumn() throws {
        let slug = try generator(
            SlugGenerator.identifier,
            params: #"{"sourceColumn":"title"}"#,
            dataType: "varchar(8)"
        )
        let row = RowContext(table: "t", rowIndex: 0, values: ["title": .text("Wireless Desk Lamp")])
        #expect(try slug.next(row: row, index: 0) == .text("wireless"))
    }

    @Test("A slug refuses to name itself or nothing")
    func slugRejectsBadSources() {
        #expect(throws: GenerationError.self) {
            _ = try generator(SlugGenerator.identifier, params: #"{"sourceColumn":"value"}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try generator(SlugGenerator.identifier, params: #"{"sourceColumn":""}"#)
        }
    }

    @Test("A slug whose source has not been generated says which column is missing")
    func slugReportsAMissingSource() throws {
        let slug = try generator(SlugGenerator.identifier, params: #"{"sourceColumn":"title"}"#)
        #expect(throws: GenerationError.self) {
            _ = try slug.next(row: RowContext(table: "t", rowIndex: 0), index: 0)
        }
    }

    // MARK: - Color

    @Test("Hex colours are six digits behind a hash")
    func hexColourShape() throws {
        let colours = try texts(generator(ColorGenerator.identifier, params: #"{"format":"hex"}"#), count: 500)
        for colour in colours {
            #expect(colour.count == 7)
            #expect(colour.hasPrefix("#"))
            #expect(colour.dropFirst().allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
        let upper = try texts(
            generator(ColorGenerator.identifier, params: #"{"format":"hex","uppercase":true}"#),
            count: 50
        )
        #expect(upper.allSatisfy { $0.dropFirst().allSatisfy { !$0.isLowercase } })
    }

    @Test("rgb colours stay inside the byte range")
    func rgbColourChannels() throws {
        let colours = try texts(generator(ColorGenerator.identifier, params: #"{"format":"rgb"}"#), count: 500)
        for colour in colours {
            let digits = colour.dropFirst(4).dropLast().components(separatedBy: ", ").compactMap { Int($0) }
            #expect(digits.count == 3)
            #expect(digits.allSatisfy { (0...255).contains($0) })
        }
    }

    /// A hex colour cut to fit is no longer a colour, so the column has to be
    /// refused at build time the way every other fixed-shape value is.
    @Test("A column too narrow for a hex colour is refused rather than truncated")
    func narrowColourColumnIsRefused() {
        #expect(throws: GenerationError.self) {
            _ = try generator(ColorGenerator.identifier, params: #"{"format":"hex"}"#, dataType: "varchar(5)")
        }
        #expect(throws: GenerationError.self) {
            _ = try generator(ColorGenerator.identifier, params: #"{"format":"rgb"}"#, dataType: "varchar(12)")
        }
    }

    @Test("Named colours never report more names than a narrow column can hold")
    func narrowNamedColoursLowerTheCount() throws {
        let narrow = try generator(ColorGenerator.identifier, params: #"{"format":"name"}"#, dataType: "varchar(3)")
        let claimed = try #require(narrow.distinctValueCount)
        let produced = Set(try texts(narrow, count: 5_000))
        #expect(claimed >= produced.count)
        #expect(claimed < 43)
    }

    // MARK: - File names and media types

    @Test("A file name is an ASCII stem and an extension, in both locales", arguments: ["en_US", "vi_VN"])
    func fileNameShape(locale: String) throws {
        let names = try texts(generator(FileNameGenerator.identifier, params: #"{"locale":"\#(locale)"}"#), count: 300)
        for name in names {
            let parts = name.split(separator: ".")
            #expect(parts.count == 2)
            #expect(name.allSatisfy { $0.isASCII })
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
            #expect(name.lowercased() == name)
        }
    }

    @Test("A file name kind restricts the extensions to that kind")
    func fileNameCategory() throws {
        let names = try texts(generator(FileNameGenerator.identifier, params: #"{"category":"image"}"#), count: 200)
        let allowed = Set(MimeTypeCatalog.fileExtensions(category: "image"))
        #expect(names.allSatisfy { allowed.contains(String($0.split(separator: ".")[1])) })
    }

    @Test("A file name never reports more values than a narrow column can hold")
    func narrowFileNameLowersTheCount() throws {
        let narrow = try generator(
            FileNameGenerator.identifier,
            params: #"{"category":"image"}"#,
            dataType: "varchar(6)"
        )
        let claimed = try #require(narrow.distinctValueCount)
        let produced = Set(try texts(narrow, count: 20_000))
        #expect(claimed >= produced.count)
    }

    @Test("A media type kind yields only that kind")
    func mimeTypeCategory() throws {
        let types = try texts(generator(MimeTypeGenerator.identifier, params: #"{"category":"video"}"#), count: 200)
        #expect(types.allSatisfy { $0.hasPrefix("video/") })
        #expect(Set(types).count > 1)
    }

    @Test("A media type list given by hand replaces the catalog")
    func mimeTypeOverride() throws {
        let types = try texts(
            generator(MimeTypeGenerator.identifier, params: #"{"types":["application/x-tablepro"]}"#),
            count: 20
        )
        #expect(Set(types) == ["application/x-tablepro"])
    }

    // MARK: - User agent and version

    @Test("A mobile user agent is a mobile browser")
    func mobileUserAgents() throws {
        let agents = try texts(generator(UserAgentGenerator.identifier, params: #"{"platform":"mobile"}"#), count: 300)
        #expect(agents.allSatisfy { $0.contains("Mobile") })
        let desktop = try texts(
            generator(UserAgentGenerator.identifier, params: #"{"platform":"desktop"}"#),
            count: 300
        )
        #expect(desktop.allSatisfy { !$0.contains("Mobile") })
    }

    @Test("The user agent count is the list it draws from")
    func userAgentCardinality() throws {
        let agent = try generator(UserAgentGenerator.identifier)
        let claimed = try #require(agent.distinctValueCount)
        let produced = Set(try texts(agent, count: 20_000))
        #expect(claimed == produced.count)
    }

    @Test("Versions stay inside their bounds")
    func semVerBounds() throws {
        let versions = try texts(
            generator(SemVerGenerator.identifier, params: #"{"maxMajor":2,"maxMinor":3,"maxPatch":4}"#),
            count: 2_000
        )
        for version in versions {
            let parts = version.split(separator: ".").compactMap { Int($0) }
            #expect(parts.count == 3)
            #expect(parts[0] <= 2 && parts[1] <= 3 && parts[2] <= 4)
        }
        #expect(Set(versions).count == 3 * 4 * 5)
    }

    @Test("A prerelease share of nothing writes no prerelease, and a full share writes one every time")
    func semVerPrereleaseShares() throws {
        let plain = try texts(generator(SemVerGenerator.identifier, params: #"{"prereleasePercent":0}"#), count: 500)
        #expect(plain.allSatisfy { !$0.contains("-") })

        let tagged = try texts(generator(SemVerGenerator.identifier, params: #"{"prereleasePercent":100}"#), count: 500)
        #expect(tagged.allSatisfy { $0.contains("-") })
        #expect(tagged.allSatisfy { version in
            ["alpha", "beta", "rc"].contains { version.contains("-\($0).") }
        })
    }

    @Test("The version count matches what a small domain really produces")
    func semVerCardinality() throws {
        let bounded = try generator(
            SemVerGenerator.identifier,
            params: #"{"maxMajor":1,"maxMinor":1,"maxPatch":1,"prereleasePercent":100}"#
        )
        let claimed = try #require(bounded.distinctValueCount)
        let produced = Set(try texts(bounded, count: 40_000))
        #expect(claimed == 8 * 27)
        #expect(claimed >= produced.count)
    }

    @Test("A leading v is written only when asked for")
    func semVerPrefix() throws {
        let prefixed = try texts(generator(SemVerGenerator.identifier, params: #"{"prefixed":true}"#), count: 50)
        #expect(prefixed.allSatisfy { $0.hasPrefix("v") })
    }
}
