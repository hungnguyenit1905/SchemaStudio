//
//  GenerationParamFormModel.swift
//  TablePro
//

import Foundation

/// Which control a parameter field is drawn as. One case per `ParamFieldType`, so
/// the view is a single switch and adding a generator never touches it.
enum GenerationParamControl: Sendable, Hashable {
    case text
    case multilineText
    case number(minimum: Int?, maximum: Int?)
    case decimal(minimum: Double?, maximum: Double?)
    case toggle
    case choice([ParamChoice])
    case stringList
    case date
}

/// The logic behind the parameter form, kept out of the view so it can be tested
/// without rendering anything.
///
/// The form edits a generator's raw `params` object in place and **never rewrites
/// the whole object**. A generator from a plugin, or a key a newer version of the
/// app wrote, has to survive being edited by a form that knows nothing about it,
/// so every write merges into what was already there.
struct GenerationParamFormModel {
    let schema: ParamSchema

    func visibleFields(in params: JSONValue) -> [ParamField] {
        schema.visibleFields(for: schema.applyingDefaults(to: params.objectValue ?? [:]))
    }

    func control(for field: ParamField) -> GenerationParamControl {
        switch field.type {
        case .text: return .text
        case .multilineText: return .multilineText
        case .integer(let minimum, let maximum): return .number(minimum: minimum, maximum: maximum)
        case .decimal(let minimum, let maximum): return .decimal(minimum: minimum, maximum: maximum)
        case .toggle: return .toggle
        case .choice(let choices): return .choice(choices)
        case .stringList: return .stringList
        case .date: return .date
        }
    }

    func value(for field: ParamField, in params: JSONValue) -> JSONValue {
        params.objectValue?[field.key] ?? field.defaultValue
    }

    func params(_ params: JSONValue, setting value: JSONValue, for field: ParamField) -> JSONValue {
        var fields = params.objectValue ?? [:]
        fields[field.key] = value
        return .object(fields)
    }

    // MARK: - Rendering and parsing

    func text(for field: ParamField, in params: JSONValue) -> String {
        switch value(for: field, in: params) {
        case .null: return ""
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return GenerationValueMapper.fixedPointText(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let elements): return elements.compactMap(Self.listItem).joined(separator: ", ")
        case .object(let object): return JSONValue.object(object).jsonText ?? ""
        }
    }

    func flag(for field: ParamField, in params: JSONValue) -> Bool {
        value(for: field, in: params).boolValue ?? false
    }

    func choiceValue(for field: ParamField, in params: JSONValue) -> String {
        guard case .choice(let choices) = field.type else { return text(for: field, in: params) }
        let current = text(for: field, in: params)
        guard choices.contains(where: { $0.value == current }) else {
            return choices.first?.value ?? current
        }
        return current
    }

    /// An empty field clears the key rather than writing an empty string: a
    /// numeric parameter left blank means "the generator decides", and `""` would
    /// fail to decode as a number.
    func params(_ params: JSONValue, settingText text: String, for field: ParamField) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch field.type {
        case .integer(let minimum, let maximum):
            guard let number = Int(trimmed) else { return clearing(field, in: params, whenEmpty: trimmed) }
            return self.params(params, setting: .int(Self.clamp(number, minimum, maximum)), for: field)
        case .decimal(let minimum, let maximum):
            guard let number = Double(trimmed) else { return clearing(field, in: params, whenEmpty: trimmed) }
            return self.params(params, setting: .double(Self.clamp(number, minimum, maximum)), for: field)
        case .stringList:
            let items = trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return self.params(params, setting: .array(items.map(JSONValue.string)), for: field)
        case .toggle:
            return self.params(params, setting: .bool(trimmed == "true"), for: field)
        default:
            return self.params(params, setting: .string(text), for: field)
        }
    }

    private func clearing(_ field: ParamField, in params: JSONValue, whenEmpty text: String) -> JSONValue {
        guard text.isEmpty else { return params }
        var fields = params.objectValue ?? [:]
        fields.removeValue(forKey: field.key)
        return .object(fields)
    }

    private static func listItem(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return GenerationValueMapper.fixedPointText(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    private static func clamp(_ value: Int, _ minimum: Int?, _ maximum: Int?) -> Int {
        var clamped = value
        if let minimum { clamped = max(clamped, minimum) }
        if let maximum { clamped = min(clamped, maximum) }
        return clamped
    }

    private static func clamp(_ value: Double, _ minimum: Double?, _ maximum: Double?) -> Double {
        var clamped = value
        if let minimum { clamped = max(clamped, minimum) }
        if let maximum { clamped = min(clamped, maximum) }
        return clamped
    }
}
