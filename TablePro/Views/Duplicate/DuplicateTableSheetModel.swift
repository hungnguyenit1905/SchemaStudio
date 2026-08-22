//
//  DuplicateTableSheetModel.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

/// Everything the sheet needs from the app, injected so the whole dialog is testable without a
/// server: naming, validation, the live preview and the enable rules are decided here, and the
/// only thing the environment supplies is data and the run itself.
struct DuplicateSheetEnvironment {
    var quoting: DuplicateSQLQuoting
    var supportsSchemas = true
    var runsOnSharedConnection = false
    var loadSchemas: () async throws -> [String] = { [] }
    var loadTakenNames: (String?) async throws -> Set<String> = { _ in [] }
    var introspect: () async throws -> DuplicateTableIntrospection
    var run: (
        DuplicateTableRequest,
        DuplicateCancellationToken,
        @escaping @Sendable (DuplicateProgress) -> Void
    ) async throws -> DuplicateResult
}

@MainActor @Observable
final class DuplicateTableSheetModel {
    enum Phase: Equatable {
        case loading
        case options
        case running
        case failed
    }

    let source: DuplicateTableRef
    let databaseType: DatabaseType

    var targetSchema: String
    var schemas: [String] = []
    var name = ""
    var mode: DuplicateMode = .structureOnly
    var options = DuplicateOptions()
    var rowFilter = ""
    var limitText = ""
    var isAdvancedExpanded = false
    var phase: Phase = .loading
    var errorMessage: String?
    var stopConfirmationShown = false

    private(set) var progress: DuplicateProgress?
    private(set) var elapsed: Duration = .zero
    private(set) var introspection: DuplicateTableIntrospection?
    private(set) var takenNames: Set<String> = []

    private let environment: DuplicateSheetEnvironment
    private let policy: TransferIdentifierPolicy
    private var suggestedName = ""
    private var token = DuplicateCancellationToken()
    private var runTask: Task<DuplicateResult, Error>?
    private var ticker: Task<Void, Never>?

    init(
        source: DuplicateTableRef,
        databaseType: DatabaseType,
        environment: DuplicateSheetEnvironment
    ) {
        self.source = source
        self.databaseType = databaseType
        self.environment = environment
        targetSchema = source.schema ?? ""
        policy = TransferIdentifierPolicy.policy(for: TransferVendor(databaseType))
    }

    // MARK: - Layout rules

    var showsTargetSchema: Bool { environment.supportsSchemas }

    var showsSharedConnectionNote: Bool { environment.runsOnSharedConnection }

    var isRowSelectionEnabled: Bool { mode == .structureAndData }

    // MARK: - Derived request

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var request: DuplicateTableRequest {
        DuplicateTableRequest(
            source: source,
            targetSchema: showsTargetSchema && !targetSchema.isEmpty ? targetSchema : nil,
            targetName: trimmedName,
            mode: mode,
            options: effectiveOptions
        )
    }

    /// The row filter and the limit only exist for a run that copies rows, so they leave the
    /// request entirely in structure-only mode instead of being carried and ignored.
    private var effectiveOptions: DuplicateOptions {
        var effective = options
        guard isRowSelectionEnabled else {
            effective.rowFilter = nil
            effective.limit = nil
            return effective
        }
        let filter = rowFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        effective.rowFilter = filter.isEmpty ? nil : filter
        effective.limit = Int64(limitText.trimmingCharacters(in: .whitespacesAndNewlines))
        return effective
    }

    var plan: DuplicatePlan? {
        guard let introspection,
              let builder = DuplicatePlanBuilder.builder(for: databaseType) else { return nil }
        return builder.plan(request: request, introspection: introspection, quoting: environment.quoting)
    }

    var previewScript: String {
        guard let plan, let introspection else { return "" }
        return DuplicatePlanPreview.script(
            plan: plan,
            harvestedIndexCount: DuplicatePlanPreview.estimatedHarvestedIndexCount(introspection.indexes),
            quoting: environment.quoting
        )
    }

    var warnings: [DuplicateWarning] { plan?.warnings ?? [] }

    // MARK: - Validation

    var nameError: DuplicateTargetNameError? {
        DuplicateTargetNaming.validate(name, policy: policy)
    }

    var nameCollides: Bool {
        !trimmedName.isEmpty && takenNames.contains(trimmedName)
    }

    /// The same check the service runs before it builds anything, so the button is disabled for
    /// the same reason the run would refuse. Whether the filter is valid SQL is the server's
    /// answer and it comes later, from the `EXPLAIN` the plan carries.
    var rowFilterProblem: String? {
        guard isRowSelectionEnabled else { return nil }
        let filter = rowFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return nil }
        guard !SQLBoundaryValidator.isRawFilterConditionSafe(filter) else { return nil }
        return DuplicateError.unsafeRowFilter.localizedDescription
    }

    var limitProblem: String? {
        guard isRowSelectionEnabled else { return nil }
        let text = limitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Int64(text), value > 0 else {
            return String(localized: "Enter a whole number of rows, or leave this empty to copy all rows.")
        }
        return nil
    }

    /// The drop path belongs to the dialog that lists the foreign keys pointing at the target and
    /// asks before cascading. Until that exists the option is refused here rather than at the
    /// server: the preflight lets it through and `CREATE TABLE` then fails on the existing name.
    var replaceUnsupportedProblem: String? {
        guard options.onExists == .dropAndRecreate else { return nil }
        return String(localized: "Replacing an existing table is not available yet. Pick a name that is free.")
    }

    var canDuplicate: Bool {
        guard phase == .options, introspection != nil else { return false }
        guard nameError == nil, rowFilterProblem == nil, limitProblem == nil else { return false }
        guard replaceUnsupportedProblem == nil else { return false }
        return plan?.isBlocked == false
    }

    // MARK: - Loading

    func load() async {
        phase = .loading
        errorMessage = nil
        do {
            let introspected = try await environment.introspect()
            introspection = introspected
            if showsTargetSchema {
                schemas = try await environment.loadSchemas()
                if !targetSchema.isEmpty, !schemas.contains(targetSchema) {
                    schemas.insert(targetSchema, at: 0)
                }
            }
            await reloadTakenNames()
            phase = .options
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    /// A schema change moves the namespace the name has to be free in, so the suggestion is
    /// recomputed there. A name the user typed is left alone: only the suggestion this model
    /// last proposed is replaced.
    func targetSchemaChanged() async {
        await reloadTakenNames()
    }

    private func reloadTakenNames() async {
        takenNames = (try? await environment.loadTakenNames(request.targetSchema)) ?? []
        guard name.isEmpty || name == suggestedName else { return }
        suggestedName = DuplicateTargetNaming.suggestedName(
            source: source.name,
            taken: takenNames,
            policy: policy
        )
        name = suggestedName
    }

    // MARK: - Running

    var statusLine: String {
        let step = progress.map { Self.stepLabel(for: $0.kind) } ?? String(localized: "Starting…")
        guard elapsed > .zero else { return step }
        return String(
            format: String(localized: "%1$@ (%2$ds)"),
            step,
            Int(elapsed.components.seconds)
        )
    }

    /// A server-side `INSERT … SELECT` reports nothing while it runs, so an atomic plan never
    /// pretends to know a percentage. Only a chunked plan, which commits batch by batch, has a
    /// fraction worth drawing, and it counts rows rather than statements: the step number stands
    /// still while hundreds of batches run.
    var progressFraction: Double? {
        guard let progress, let copied = progress.copiedRows, let total = progress.totalRows, total > 0 else {
            return nil
        }
        return min(1, Double(copied) / Double(total))
    }

    /// A limit caps the copy however large the source is, so the number shown is the smaller of
    /// the two rather than a figure the run will never reach.
    var estimatedRowCount: Int {
        guard isRowSelectionEnabled, let rows = plan?.estimatedRowCount else { return 0 }
        guard let limit = request.options.limit else { return Int(rows) }
        return Int(min(rows, limit))
    }

    var progressFootnote: String {
        guard isRowSelectionEnabled else {
            return String(localized: "Stopping rolls back the new table.")
        }
        guard plan?.copyMode != .chunked else {
            return String(
                localized: """
                The rows are copied in batches that each commit. Stopping finishes the batch that is \
                running and then asks whether to keep or delete what was copied.
                """
            )
        }
        return String(
            localized: """
            The row count is the planner's estimate for the source table. The copy runs as one \
            server-side statement, so there is no percentage. Stopping rolls it back.
            """
        )
    }

    func duplicate() async -> DuplicateResult? {
        guard canDuplicate else { return nil }
        let attempt = request
        phase = .running
        errorMessage = nil
        progress = nil
        token = DuplicateCancellationToken()
        startTicker()
        defer { stopTicker() }

        let task = Task {
            try await environment.run(attempt, token) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
        }
        runTask = task
        defer { runTask = nil }

        do {
            return try await task.value
        } catch {
            errorMessage = error is CancellationError
                ? DuplicateError.cancelled.localizedDescription
                : error.localizedDescription
            phase = .options
            return nil
        }
    }

    func requestStop() {
        stopConfirmationShown = true
    }

    /// Both halves of stopping. The token ends the run between statements, and cancelling the
    /// task reaches the statement that is already at the server: the driver lease was taken with
    /// cancellation tracking, so it sends the vendor's own cancel for the query in flight.
    func confirmStop() {
        token.cancel()
        runTask?.cancel()
    }

    func tearDown() {
        stopTicker()
        token.cancel()
        runTask?.cancel()
    }

    private func startTicker() {
        elapsed = .zero
        let startedAt = ContinuousClock.now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.elapsed = ContinuousClock.now - startedAt
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    static func stepLabel(for kind: DuplicateStatement.Kind) -> String {
        switch kind {
        case .validateRowFilter:
            return String(localized: "Checking the row filter…")
        case .createTable:
            return String(localized: "Creating the table…")
        case .tableComment:
            return String(localized: "Copying the table comment…")
        case .harvestIndexes:
            return String(localized: "Reading the new table's indexes…")
        case .dropIndex:
            return String(localized: "Setting indexes aside…")
        case .createSequence, .ownSequence:
            return String(localized: "Creating sequences…")
        case .setColumnDefault:
            return String(localized: "Setting column defaults…")
        case .copyData:
            return String(localized: "Copying rows…")
        case .replayIndex:
            return String(localized: "Recreating indexes…")
        case .resetSequence:
            return String(localized: "Resetting sequences…")
        case .addForeignKey:
            return String(localized: "Creating foreign keys…")
        case .analyze:
            return String(localized: "Updating table statistics…")
        case .dropTarget:
            return String(localized: "Removing the existing table…")
        case .dropReferencingForeignKey:
            return String(localized: "Removing foreign keys that point at it…")
        }
    }
}
