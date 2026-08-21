//
//  GenerationProfileListView.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Saved profiles and the templates that ship with the app. Loading one shows
/// what it would change first; the diff replaces this list until the user has
/// answered it.
struct GenerationProfileListView: View {
    @Bindable var model: DataGenerationWizardModel
    @Binding var isPresented: Bool

    @State private var newProfileName = ""

    var body: some View {
        Group {
            if let diff = model.pendingDiff {
                GenerationProfileDiffView(
                    diff: diff,
                    onApply: {
                        model.applyPendingProfile()
                        isPresented = false
                    },
                    onCancel: { model.discardPendingProfile() }
                )
            } else {
                list
            }
        }
        .frame(width: 620, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refreshSavedProfiles() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            saveRow
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Profiles")
                .font(.title3.weight(.semibold))
            Text("A profile remembers the tables, the generators and the seed. It never holds a password.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var content: some View {
        List {
            Section(String(localized: "Saved")) {
                if model.savedProfiles.isEmpty {
                    Text("Nothing saved yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.savedProfiles) { saved in
                        savedRow(saved)
                    }
                }
            }
            Section(String(localized: "Templates")) {
                ForEach(model.templates) { template in
                    templateRow(template)
                }
            }
        }
        .listStyle(.inset)
    }

    private func savedRow(_ saved: SavedGenerationProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.profile.name)
                    .font(.callout.weight(.medium))
                Text(subtitle(for: saved))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Load")) {
                model.prepareToLoad(saved.profile)
                if model.pendingDiff == nil { isPresented = false }
            }
            .disabled(model.schemaFacts.isEmpty)
            Button(String(localized: "Export")) { export(saved.profile) }
            Button(role: .destructive) {
                Task { await model.deleteProfile(saved) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func templateRow(_ template: GenerationTemplate) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.callout.weight(.medium))
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Apply")) {
                if model.applyTemplate(template) { isPresented = false }
            }
            .disabled(model.schemaFacts.isEmpty)
        }
        .padding(.vertical, 2)
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(String(localized: "Name this setup"), text: $newProfileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("generation.profile.name")
                Button(String(localized: "Save")) {
                    let name = newProfileName
                    newProfileName = ""
                    Task { await model.saveCurrentProfile(named: name) }
                }
                .disabled(!model.canSaveProfile || newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("generation.profile.save")
            }
            if !model.canSaveProfile {
                Text("Pick the tables first, then come back to save them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.profileMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Import…")) { importProfile() }
                .disabled(model.schemaFacts.isEmpty)
            Spacer()
            Button(String(localized: "Done")) { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func subtitle(for saved: SavedGenerationProfile) -> String {
        let tables = String(format: String(localized: "%d tables"), saved.profile.tables.count)
        let scope = saved.profile.scope?.summary ?? ""
        return scope.isEmpty ? tables : "\(tables) · \(scope)"
    }

    private func export(_ profile: GenerationProfile) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = GenerationProfileExporter.suggestedFileName(for: profile)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            model.exportProfile(profile, to: url)
        }
    }

    private func importProfile() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard model.importProfile(from: url) else { return }
            if model.pendingDiff == nil { isPresented = false }
        }
    }
}
