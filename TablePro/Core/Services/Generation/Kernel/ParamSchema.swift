//
//  ParamSchema.swift
//  TablePro
//

import Foundation

struct ParamChoice: Sendable, Hashable {
    let value: String
    let label: String

    init(value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

enum ParamFieldType: Sendable, Hashable {
    case text
    case multilineText
    case integer(minimum: Int?, maximum: Int?)
    case decimal(minimum: Double?, maximum: Double?)
    case toggle
    case choice([ParamChoice])
    case stringList
    case date
}

struct ParamVisibility: Sendable, Hashable {
    let key: String
    let equalsAnyOf: [JSONValue]

    func isSatisfied(by params: [String: JSONValue]) -> Bool {
        guard let current = params[key] else { return false }
        return equalsAnyOf.contains(current)
    }
}

struct ParamField: Sendable, Hashable {
    let key: String
    let label: String
    let type: ParamFieldType
    let defaultValue: JSONValue
    let help: String?
    let visibleWhen: ParamVisibility?

    init(
        key: String,
        label: String,
        type: ParamFieldType,
        defaultValue: JSONValue,
        help: String? = nil,
        visibleWhen: ParamVisibility? = nil
    ) {
        self.key = key
        self.label = label
        self.type = type
        self.defaultValue = defaultValue
        self.help = help
        self.visibleWhen = visibleWhen
    }
}

struct ParamSchema: Sendable, Hashable {
    let fields: [ParamField]

    init(fields: [ParamField] = []) {
        self.fields = fields
    }

    static let empty = ParamSchema()

    var defaults: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })
    }

    func visibleFields(for params: [String: JSONValue]) -> [ParamField] {
        fields.filter { field in
            guard let visibility = field.visibleWhen else { return true }
            return visibility.isSatisfied(by: params)
        }
    }

    func applyingDefaults(to params: [String: JSONValue]) -> [String: JSONValue] {
        defaults.merging(params) { _, provided in provided }
    }
}
