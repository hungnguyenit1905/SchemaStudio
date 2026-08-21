//
//  DataGenerationWizardModel+Profiles.swift
//  TablePro
//

import Foundation

@MainActor
extension DataGenerationWizardModel {
    var currentProfileScope: GenerationProfileScope {
        GenerationProfileScope(
            connectionName: connection(for: connectionId)?.name,
            database: database.isEmpty ? nil : database,
            schema: schema
        )
    }

    var canSaveProfile: Bool { !profile.tables.isEmpty }

    // MARK: - Saved profiles

    func refreshSavedProfiles() async {
        isLoadingProfiles = true
        defer { isLoadingProfiles = false }
        savedProfiles = await GenerationProfileStorage.shared.list()
    }

    func saveCurrentProfile(named name: String, id: UUID? = nil) async {
        guard canSaveProfile else { return }
        var saved = profile
        saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.scope = currentProfileScope
        _ = await GenerationProfileStorage.shared.save(saved, id: id ?? UUID())
        profileMessage = String(format: String(localized: "Saved %@."), saved.name)
        await refreshSavedProfiles()
    }

    func deleteProfile(_ saved: SavedGenerationProfile) async {
        await GenerationProfileStorage.shared.delete(id: saved.id)
        await refreshSavedProfiles()
    }

    // MARK: - Loading

    /// Reconciles a profile against the schema as it is now and holds it until the
    /// user has seen what changed. A profile that needs no changes is adopted
    /// straight away: there is nothing to review.
    func prepareToLoad(_ profile: GenerationProfile) {
        profileMessage = nil
        let reconciliation = GenerationProfileReconciler().reconcile(profile, against: schemaFacts)
        let diff = GenerationProfileDiff(reconciliation: reconciliation)
        guard !diff.isEmpty else {
            adopt(reconciliation.profile, warnings: reconciliation.warnings)
            step = .columns
            return
        }
        pendingProfile = reconciliation.profile
        pendingWarnings = reconciliation.warnings
        pendingDiff = diff
    }

    func applyPendingProfile() {
        guard let pendingProfile else { return }
        adopt(pendingProfile, warnings: pendingWarnings)
        discardPendingProfile()
        step = .columns
    }

    func discardPendingProfile() {
        pendingProfile = nil
        pendingDiff = nil
        pendingWarnings = []
    }

    // MARK: - Export and import

    func exportProfile(_ profile: GenerationProfile, to url: URL) {
        do {
            try GenerationProfileExporter.write(profile, to: url)
            profileMessage = String(format: String(localized: "Exported %@."), profile.name)
        } catch {
            profileMessage = error.localizedDescription
        }
    }

    /// An imported profile is bound to whatever connection is open in the wizard:
    /// the file names a connection, it never identifies one.
    ///
    /// Returns whether the file was read. The caller closes the sheet on success and
    /// leaves it open on failure so the reason stays on screen.
    @discardableResult
    func importProfile(from url: URL) -> Bool {
        do {
            var imported = try GenerationProfileExporter.read(from: url)
            let origin = imported.scope
            imported.scope = currentProfileScope
            prepareToLoad(imported)
            profileMessage = importMessage(origin: origin)
            return true
        } catch {
            profileMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func importMessage(origin: GenerationProfileScope?) -> String? {
        guard let origin, !origin.isEmpty else { return nil }
        let current = currentProfileScope
        guard origin.connectionName != current.connectionName || origin.database != current.database else {
            return nil
        }
        return String(
            format: String(localized: "This profile was built against %@. It is now bound to %@."),
            origin.summary,
            current.summary
        )
    }

    // MARK: - Templates

    var templates: [GenerationTemplate] { GenerationTemplateCatalog.builtin() }

    /// Returns whether the template was applied. A refused template leaves the
    /// wizard where it was, with the reason in `profileMessage`.
    @discardableResult
    func applyTemplate(_ template: GenerationTemplate) -> Bool {
        profileMessage = nil
        do {
            let application = try GenerationTemplateApplier().apply(
                template,
                to: schemaFacts,
                seed: UInt64(seedText) ?? GenerationSeed.randomSeed(),
                scope: currentProfileScope
            )
            adopt(application.profile, warnings: application.warnings)
            profileMessage = templateMessage(for: application)
            step = .columns
            return true
        } catch {
            profileMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func templateMessage(for application: GenerationTemplateApplication) -> String {
        guard !application.isComplete else {
            return String(
                format: String(localized: "Filled %d tables."),
                application.matchedTables.count
            )
        }
        var parts: [String] = [
            String(format: String(localized: "Filled %d tables."), application.matchedTables.count)
        ]
        if !application.unmatchedTables.isEmpty {
            parts.append(
                String(
                    format: String(localized: "Not in this database: %@."),
                    application.unmatchedTables.joined(separator: ", ")
                )
            )
        }
        if !application.unmatchedColumns.isEmpty {
            parts.append(
                String(
                    format: String(localized: "Auto-mapped instead: %@."),
                    application.unmatchedColumns.joined(separator: ", ")
                )
            )
        }
        return parts.joined(separator: " ")
    }
}
