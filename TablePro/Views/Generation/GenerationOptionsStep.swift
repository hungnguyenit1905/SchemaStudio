//
//  GenerationOptionsStep.swift
//  TablePro
//

import SwiftUI

/// Step three: how the rows are written, and what the pre-flight found.
///
/// An option the target cannot honour is disabled with the reason next to it rather
/// than accepted and quietly ignored.
struct GenerationOptionsStep: View {
    @Bindable var model: DataGenerationWizardModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            options
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            checks
                .frame(width: 300, alignment: .topLeading)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(String(localized: "Empty each table before generating"), isOn: $model.emptyFirst)
                .disabled(model.emptyFirstDisabledReason != nil)
                .accessibilityIdentifier("generation.emptyFirst")
            if let reason = model.emptyFirstDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Toggle(String(localized: "Write everything in one transaction"), isOn: $model.singleTransaction)
            Text("A failure then leaves the database exactly as it was. Very large runs can exhaust the server's undo space.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Toggle(String(localized: "Keep going after a failed batch"), isOn: $model.continueOnError)

            Toggle(String(localized: "Disable foreign key checks"), isOn: $model.disablesForeignKeyChecks)
                .disabled(model.disablesForeignKeyChecksDisabledReason != nil)
                .accessibilityIdentifier("generation.disablesForeignKeyChecks")
            if let reason = model.disablesForeignKeyChecksDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            } else {
                Text("Lets tables that point at each other load out of order. Turned back on before the run ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }

            Toggle(String(localized: "Disable triggers"), isOn: $model.disablesTriggers)
                .accessibilityIdentifier("generation.disablesTriggers")
            Text("Reported as skipped on engines that cannot do it. Turned back on per table as soon as its rows are written.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Spacer()
        }
        .padding(20)
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before the run")
                .font(.subheadline.weight(.semibold))

            if model.validationErrors.isEmpty {
                Label(String(localized: "Nothing is in the way."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                ForEach(Array(model.validationErrors.enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(error.errorDescription ?? "", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        if let suggestion = error.recoverySuggestion {
                            Text(suggestion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                    }
                }
            }

            if !model.mappingWarnings.isEmpty {
                Divider()
                Text("Worth a look")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.mappingWarnings, id: \.self) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Spacer()
        }
        .padding(20)
    }
}
