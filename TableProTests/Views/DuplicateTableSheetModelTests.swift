//
//  DuplicateTableSheetModelTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@MainActor
@Suite("DuplicateTableSheetModel")
struct DuplicateTableSheetModelTests {
    private func makeModel(
        databaseType: DatabaseType = .postgresql,
        supportsSchemas: Bool = true,
        introspection: DuplicateTableIntrospection = DuplicateFixtures.threeIndexTable,
        taken: Set<String> = [],
        schemas: [String] = ["public", "reporting"],
        run: @escaping (DuplicateTableRequest) async throws -> DuplicateResult = { request in
            DuplicateResult(target: request.target, warnings: [], executedStatements: [])
        }
    ) -> DuplicateTableSheetModel {
        let environment = DuplicateSheetEnvironment(
            quoting: DuplicateFixtures.quoting,
            supportsSchemas: supportsSchemas,
            runsOnSharedConnection: false,
            loadSchemas: { schemas },
            loadTakenNames: { _ in taken },
            introspect: { introspection },
            run: { request, _, _ in try await run(request) }
        )
        return DuplicateTableSheetModel(
            source: DuplicateTableRef(schema: "public", name: "orders"),
            databaseType: databaseType,
            environment: environment
        )
    }

    // MARK: - Naming

    @Test("A free name is suggested with the plain _copy suffix")
    func suggestsPlainCopy() async {
        let model = makeModel()
        await model.load()
        #expect(model.name == "orders_copy")
        #expect(model.canDuplicate)
    }

    @Test("A taken name is skipped when the suggestion is made")
    func suggestsNumberedCopy() async {
        let model = makeModel(taken: ["orders_copy", "orders_copy1"])
        await model.load()
        #expect(model.name == "orders_copy2")
    }

    @Test("An empty name disables Duplicate")
    func emptyNameBlocks() async {
        let model = makeModel()
        await model.load()
        model.name = "   "
        #expect(model.nameError == .empty)
        #expect(!model.canDuplicate)
    }

    /// The limit is a byte budget, so a name written with diacritics runs out of room far earlier
    /// than its character count suggests.
    @Test("A name over the byte budget disables Duplicate")
    func longNameBlocks() async {
        let model = makeModel()
        await model.load()
        model.name = String(repeating: "á", count: 40)
        #expect(model.nameError == .tooLongForVendor(limitBytes: 63))
        #expect(!model.canDuplicate)
    }

    @Test("A name that already exists is flagged without blocking")
    func collisionIsANote() async {
        let model = makeModel(taken: ["orders_copy"])
        await model.load()
        model.name = "orders_copy"
        #expect(model.nameCollides)
        #expect(model.canDuplicate)
    }

    // MARK: - Mode

    @Test("Row filter and limit only apply when the run copies rows")
    func rowSelectionFollowsMode() async {
        let model = makeModel()
        await model.load()
        model.rowFilter = "total > 100"
        model.limitText = "500"

        #expect(!model.isRowSelectionEnabled)
        #expect(model.request.options.rowFilter == nil)
        #expect(model.request.options.limit == nil)

        model.mode = .structureAndData
        #expect(model.isRowSelectionEnabled)
        #expect(model.request.options.rowFilter == "total > 100")
        #expect(model.request.options.limit == 500)
    }

    @Test("A row filter carrying a statement separator disables Duplicate")
    func unsafeRowFilterBlocks() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        model.rowFilter = "1=1; DROP TABLE orders"
        #expect(model.rowFilterProblem != nil)
        #expect(!model.canDuplicate)
    }

    @Test("A limit that is not a positive whole number disables Duplicate")
    func invalidLimitBlocks() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        model.limitText = "0"
        #expect(model.limitProblem != nil)
        #expect(!model.canDuplicate)
    }

    // MARK: - Schemas

    @Test("Target schema is hidden and unset where the connection has no schemas")
    func schemaHiddenWithoutSchemaSupport() async {
        let model = makeModel(databaseType: .postgresql, supportsSchemas: false)
        await model.load()
        #expect(!model.showsTargetSchema)
        #expect(model.request.targetSchema == nil)
        #expect(model.schemas.isEmpty)
    }

    @Test("Target schema defaults to the source schema and lists the rest")
    func schemaShownWithSchemaSupport() async {
        let model = makeModel()
        await model.load()
        #expect(model.showsTargetSchema)
        #expect(model.targetSchema == "public")
        #expect(model.schemas == ["public", "reporting"])
        #expect(model.request.targetSchema == "public")
    }

    // MARK: - Warnings

    @Test("A partitioned source blocks the run")
    func partitionedSourceBlocks() async {
        let model = makeModel(introspection: DuplicateFixtures.partitionedTable)
        await model.load()
        #expect(model.warnings.contains(.partitionedTableNotSupported("orders")))
        #expect(!model.canDuplicate)
    }

    @Test("Row-level security on a table the user owns shows one warning")
    func ownedRowLevelSecurityWarning() async {
        let model = makeModel(introspection: DuplicateFixtures.rowLevelSecurityOwnedTable)
        await model.load()
        #expect(model.warnings == [.rowLevelSecurityPoliciesNotCopied])
        #expect(model.canDuplicate)
    }

    /// The second warning is about missing rows, not about missing policies, so it stays separate
    /// and only appears when the reader is not the owner.
    @Test("Row-level security on someone else's table shows both warnings")
    func foreignRowLevelSecurityWarnings() async {
        let model = makeModel(introspection: DuplicateFixtures.rowLevelSecurityForeignTable)
        await model.load()
        #expect(
            model.warnings == [.rowLevelSecurityPoliciesNotCopied, .rowLevelSecurityMayHideRows]
        )
    }

    // MARK: - Preview

    @Test("The preview follows the option checkboxes")
    func previewFollowsOptions() async {
        let model = makeModel()
        await model.load()
        #expect(model.previewScript.contains("INCLUDING INDEXES"))
        model.options.indexes = false
        #expect(!model.previewScript.contains("INCLUDING INDEXES"))
    }

    @Test("The preview labels the statements that only exist once the run starts")
    func previewLabelsDeferredBlock() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        #expect(model.previewScript.contains("Generated when this runs"))
        #expect(model.previewScript.contains("3 index"))
    }

    // MARK: - Progress

    @Test("An atomic plan reports no percentage")
    func atomicProgressIsIndeterminate() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        #expect(model.progressFraction == nil)
    }

    /// The estimate is what the run will actually copy, so a limit caps it rather than showing a
    /// figure the copy stops short of.
    @Test("A row limit caps the estimated row count the sheet shows")
    func limitCapsTheEstimate() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        model.limitText = "10"
        #expect(model.estimatedRowCount == 10)
    }

    /// A chunked copy commits every batch, so the footnote must not promise a rollback.
    @Test("A chunked plan's footnote describes batches, not a rollback")
    func chunkedFootnoteDescribesBatches() async {
        let model = makeModel()
        await model.load()
        model.mode = .structureAndData
        model.options.copyMode = .chunked
        #expect(model.plan?.copyMode == .chunked)
        #expect(!model.progressFootnote.contains("rolls"))
        #expect(model.warnings.contains(.chunkedCopyIsNotASnapshot))
    }

    // MARK: - Running

    @Test("Duplicate runs the request the sheet built")
    func runUsesBuiltRequest() async {
        let recorder = Recorder()
        let model = makeModel(run: { request in
            await recorder.store(request)
            return DuplicateResult(target: request.target, warnings: [], executedStatements: [])
        })
        await model.load()
        model.mode = .structureAndData
        let result = await model.duplicate()

        #expect(result?.target.name == "orders_copy")
        let recorded = await recorder.request
        #expect(recorded?.targetName == "orders_copy")
        #expect(recorded?.mode == .structureAndData)
    }

    @Test("A failed run keeps the options step and shows the message")
    func failedRunReturnsToOptions() async {
        let model = makeModel(run: { _ in throw DuplicateError.targetExists("orders_copy") })
        await model.load()
        let result = await model.duplicate()

        #expect(result == nil)
        #expect(model.phase == .options)
        #expect(model.errorMessage != nil)
    }

    @Test("Replacing an existing table is refused until the drop dialog exists")
    func dropAndRecreateRefused() async {
        let model = makeModel()
        await model.load()
        model.options.onExists = .dropAndRecreate
        #expect(model.replaceUnsupportedProblem != nil)
        #expect(!model.canDuplicate)
    }

    private actor Recorder {
        private(set) var request: DuplicateTableRequest?

        func store(_ request: DuplicateTableRequest) {
            self.request = request
        }
    }
}
