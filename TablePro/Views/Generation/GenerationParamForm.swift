//
//  GenerationParamForm.swift
//  TablePro
//

import SwiftUI

/// One form for every generator, drawn from its `ParamSchema`.
///
/// There is deliberately no per-generator form: with around a hundred generators
/// in the catalog, a hand-written form each would mean adding a generator touches
/// three files and the forms drift from what the generator actually reads.
struct GenerationParamForm: View {
    let schema: ParamSchema
    @Binding var params: JSONValue

    /// What the user has typed, before it is parsed and clamped back into
    /// `params`. Without it a numeric field reads its own clamped value back on
    /// every keystroke, so a partial entry like `-` or `1` in a field whose
    /// minimum is higher is rewritten mid-word and cannot be finished. The draft
    /// is dropped on focus loss so the field then shows the value actually held.
    @State private var drafts: [String: String] = [:]
    @FocusState private var focusedField: String?

    private var model: GenerationParamFormModel { GenerationParamFormModel(schema: schema) }

    var body: some View {
        let fields = model.visibleFields(in: params)
        if fields.isEmpty {
            Text("This generator has no settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields, id: \.key) { field in
                    row(for: field)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: focusedField) { previous, _ in
                guard let previous else { return }
                drafts[previous] = nil
            }
        }
    }

    private func row(for field: ParamField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.label)
                    .font(.callout)
                    .frame(width: 150, alignment: .leading)
                control(for: field)
            }
            if let help = field.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 158)
            }
        }
    }

    @ViewBuilder private func control(for field: ParamField) -> some View {
        switch model.control(for: field) {
        case .toggle:
            Toggle("", isOn: flagBinding(for: field))
                .labelsHidden()
                .accessibilityIdentifier("generation.param.\(field.key)")
        case .choice(let choices):
            Picker("", selection: choiceBinding(for: field)) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("generation.param.\(field.key)")
        case .multilineText:
            TextEditor(text: textBinding(for: field))
                .font(.body)
                .frame(minHeight: 60)
                .focused($focusedField, equals: field.key)
                .accessibilityIdentifier("generation.param.\(field.key)")
        case .text, .number, .decimal, .stringList, .date:
            TextField(placeholder(for: field), text: textBinding(for: field))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field.key)
                .accessibilityIdentifier("generation.param.\(field.key)")
        }
    }

    private func placeholder(for field: ParamField) -> String {
        switch model.control(for: field) {
        case .stringList: return String(localized: "Comma separated")
        case .date: return String(localized: "YYYY-MM-DD")
        case .number, .decimal: return String(localized: "Generator's choice")
        default: return ""
        }
    }

    private func textBinding(for field: ParamField) -> Binding<String> {
        Binding(
            get: { drafts[field.key] ?? model.text(for: field, in: params) },
            set: { typed in
                drafts[field.key] = typed
                params = model.params(params, settingText: typed, for: field)
            }
        )
    }

    private func flagBinding(for field: ParamField) -> Binding<Bool> {
        Binding(
            get: { model.flag(for: field, in: params) },
            set: { params = model.params(params, setting: .bool($0), for: field) }
        )
    }

    private func choiceBinding(for field: ParamField) -> Binding<String> {
        Binding(
            get: { model.choiceValue(for: field, in: params) },
            set: { params = model.params(params, setting: .string($0), for: field) }
        )
    }
}
