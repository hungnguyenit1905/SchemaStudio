//
//  GenerationParamFormTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("GenerationParamForm")
struct GenerationParamFormTests {
    private static let schema = ParamSchema(fields: [
        ParamField(key: "name", label: "Name", type: .text, defaultValue: .string("")),
        ParamField(key: "notes", label: "Notes", type: .multilineText, defaultValue: .string("")),
        ParamField(key: "count", label: "Count", type: .integer(minimum: 1, maximum: 10), defaultValue: .int(3)),
        ParamField(key: "ratio", label: "Ratio", type: .decimal(minimum: 0, maximum: 1), defaultValue: .double(0.5)),
        ParamField(key: "loud", label: "Loud", type: .toggle, defaultValue: .bool(true)),
        ParamField(
            key: "mode",
            label: "Mode",
            type: .choice([ParamChoice(value: "fast"), ParamChoice(value: "slow")]),
            defaultValue: .string("fast")
        ),
        ParamField(key: "values", label: "Values", type: .stringList, defaultValue: .array([])),
        ParamField(key: "from", label: "From", type: .date, defaultValue: .string("2024-01-01"))
    ])

    private static let model = GenerationParamFormModel(schema: schema)

    private static func field(_ key: String) throws -> ParamField {
        try #require(schema.fields.first { $0.key == key })
    }

    @Test("Every field type maps to its own control")
    func everyFieldTypeHasAControl() throws {
        #expect(Self.model.control(for: try Self.field("name")) == .text)
        #expect(Self.model.control(for: try Self.field("notes")) == .multilineText)
        #expect(Self.model.control(for: try Self.field("count")) == .number(minimum: 1, maximum: 10))
        #expect(Self.model.control(for: try Self.field("ratio")) == .decimal(minimum: 0, maximum: 1))
        #expect(Self.model.control(for: try Self.field("loud")) == .toggle)
        #expect(
            Self.model.control(for: try Self.field("mode"))
                == .choice([ParamChoice(value: "fast"), ParamChoice(value: "slow")])
        )
        #expect(Self.model.control(for: try Self.field("values")) == .stringList)
        #expect(Self.model.control(for: try Self.field("from")) == .date)
    }

    @Test("A field with no stored value shows its default")
    func defaultsAreShown() throws {
        let empty = JSONValue.object([:])
        #expect(Self.model.text(for: try Self.field("count"), in: empty) == "3")
        #expect(Self.model.flag(for: try Self.field("loud"), in: empty))
        #expect(Self.model.choiceValue(for: try Self.field("mode"), in: empty) == "fast")
        #expect(Self.model.text(for: try Self.field("from"), in: empty) == "2024-01-01")
    }

    @Test("A stored value wins over the default")
    func storedValuesAreShown() throws {
        let params = JSONValue.object(["count": .int(7), "loud": .bool(false), "mode": .string("slow")])
        #expect(Self.model.text(for: try Self.field("count"), in: params) == "7")
        #expect(!Self.model.flag(for: try Self.field("loud"), in: params))
        #expect(Self.model.choiceValue(for: try Self.field("mode"), in: params) == "slow")
    }

    @Test("Editing one field leaves every other key alone, known or not")
    func editingPreservesUnknownKeys() throws {
        let params = JSONValue.object([
            "count": .int(4),
            "somethingThisVersionDoesNotKnow": .string("keep me"),
            "nested": .object(["deep": .bool(true)])
        ])
        let edited = Self.model.params(params, settingText: "9", for: try Self.field("count"))
        let fields = try #require(edited.objectValue)

        #expect(fields["count"] == .int(9))
        #expect(fields["somethingThisVersionDoesNotKnow"] == .string("keep me"))
        #expect(fields["nested"] == .object(["deep": .bool(true)]))
    }

    @Test("A number outside the field's range is clamped, not rejected")
    func numbersAreClamped() throws {
        let count = try Self.field("count")
        #expect(Self.model.params(.object([:]), settingText: "99", for: count).objectValue?["count"] == .int(10))
        #expect(Self.model.params(.object([:]), settingText: "-5", for: count).objectValue?["count"] == .int(1))

        let ratio = try Self.field("ratio")
        #expect(Self.model.params(.object([:]), settingText: "3.5", for: ratio).objectValue?["ratio"] == .double(1))
    }

    @Test("Clearing a numeric field hands the choice back to the generator")
    func clearingANumberRemovesTheKey() throws {
        let params = JSONValue.object(["count": .int(4), "name": .string("keep")])
        let cleared = Self.model.params(params, settingText: "", for: try Self.field("count"))
        #expect(cleared.objectValue?["count"] == nil)
        #expect(cleared.objectValue?["name"] == .string("keep"))
    }

    @Test("Text that is not a number is ignored rather than written")
    func nonNumericTextIsIgnored() throws {
        let params = JSONValue.object(["count": .int(4)])
        let edited = Self.model.params(params, settingText: "abc", for: try Self.field("count"))
        #expect(edited.objectValue?["count"] == .int(4))
    }

    @Test("A list round trips through its comma separated form")
    func listRoundTrips() throws {
        let values = try Self.field("values")
        let edited = Self.model.params(.object([:]), settingText: "new, paid , shipped", for: values)
        #expect(edited.objectValue?["values"] == .array([.string("new"), .string("paid"), .string("shipped")]))
        #expect(Self.model.text(for: values, in: edited) == "new, paid, shipped")
    }

    @Test("A choice that is no longer offered falls back to the first one")
    func staleChoiceFallsBack() throws {
        let params = JSONValue.object(["mode": .string("removed-in-this-version")])
        #expect(Self.model.choiceValue(for: try Self.field("mode"), in: params) == "fast")
    }

    @Test("A conditional field appears only once its condition holds")
    func conditionalFieldsFollowTheirCondition() {
        let schema = ParamSchema(fields: [
            ParamField(
                key: "charset",
                label: "Characters",
                type: .choice([ParamChoice(value: "alphanumeric"), ParamChoice(value: "custom")]),
                defaultValue: .string("alphanumeric")
            ),
            ParamField(
                key: "customCharacters",
                label: "Custom characters",
                type: .text,
                defaultValue: .string(""),
                visibleWhen: ParamVisibility(key: "charset", equalsAnyOf: [.string("custom")])
            )
        ])
        let model = GenerationParamFormModel(schema: schema)

        #expect(model.visibleFields(in: .object([:])).map(\.key) == ["charset"])
        #expect(
            model.visibleFields(in: .object(["charset": .string("custom")])).map(\.key)
                == ["charset", "customCharacters"]
        )
    }

    @Test("Every generator in the catalog renders a form with no per-generator code")
    func everyRegisteredGeneratorRenders() {
        var renderedControls: Set<String> = []
        for identifier in GeneratorRegistry.standard.identifiers {
            guard let schema = GeneratorRegistry.standard.paramSchema(for: identifier) else {
                Issue.record("\(identifier) has no parameter schema")
                continue
            }
            let model = GenerationParamFormModel(schema: schema)
            for field in model.visibleFields(in: .object([:])) {
                let control = model.control(for: field)
                renderedControls.insert("\(control)")
                let edited = model.params(
                    .object([:]),
                    settingText: model.text(for: field, in: .object([:])),
                    for: field
                )
                #expect(edited.objectValue != nil, "\(identifier).\(field.key) lost its params object")
            }
        }
        #expect(renderedControls.count >= 5, "the catalog should exercise most control kinds")
    }

    /// The success criterion for the schema-driven form: a generator the form has
    /// never heard of renders from its schema alone.
    @Test("A generator added without touching the form still renders")
    func unknownGeneratorRenders() {
        let schema = ParamSchema(fields: [
            ParamField(key: "flavour", label: "Flavour", type: .text, defaultValue: .string("vanilla")),
            ParamField(key: "scoops", label: "Scoops", type: .integer(minimum: 1, maximum: 3), defaultValue: .int(1))
        ])
        let model = GenerationParamFormModel(schema: schema)
        let fields = model.visibleFields(in: .object([:]))

        #expect(fields.map(\.key) == ["flavour", "scoops"])
        #expect(model.control(for: fields[0]) == .text)
        #expect(model.control(for: fields[1]) == .number(minimum: 1, maximum: 3))
        #expect(model.text(for: fields[0], in: .object([:])) == "vanilla")
    }
}
