import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@MainActor
@Suite("DataTransfer preflight")
struct TransferPreflightTests {
    private let targetColumns = [
        PluginColumnInfo(name: "id", dataType: "int", isPrimaryKey: true),
        PluginColumnInfo(name: "name", dataType: "varchar(64)"),
        PluginColumnInfo(name: "note", dataType: "text")
    ]

    @Test("A target missing a source column fails before anything is emptied")
    func missingColumnFails() {
        let missing = DataTransferService.missingTargetColumns(
            required: ["id", "name", "total"],
            targetColumns: targetColumns
        )
        #expect(missing == ["total"])
    }

    @Test("A target that covers every source column passes")
    func coveredColumnsPass() {
        let missing = DataTransferService.missingTargetColumns(
            required: ["id", "name"],
            targetColumns: targetColumns
        )
        #expect(missing.isEmpty)
    }

    @Test("An extra column at the target is reported, not treated as a failure")
    func extraColumnIsOnlyReported() {
        let extra = DataTransferService.unmatchedTargetColumns(
            required: ["id", "name"],
            targetColumns: targetColumns
        )
        #expect(extra == ["note"])
    }

    @Test("A generated column of the source is not required at the target")
    func generatedColumnIsNotRequired() {
        let structure = TransferStructureBuilder.build(
            table: "orders",
            columns: [
                PluginColumnInfo(name: "id", dataType: "int", isPrimaryKey: true),
                PluginColumnInfo(name: "name", dataType: "varchar(64)"),
                PluginColumnInfo(name: "total", dataType: "int", isGenerated: true)
            ],
            indexes: [],
            foreignKeys: [],
            targetSchema: nil
        )
        let missing = DataTransferService.missingTargetColumns(
            required: structure.writableColumns,
            targetColumns: targetColumns
        )
        #expect(missing.isEmpty)
    }

    @Test("A generated column at the target is not reported as an extra column")
    func generatedTargetColumnIsNotExtra() {
        let extra = DataTransferService.unmatchedTargetColumns(
            required: ["id"],
            targetColumns: [
                PluginColumnInfo(name: "id", dataType: "int", isPrimaryKey: true),
                PluginColumnInfo(name: "total", dataType: "int", isGenerated: true)
            ]
        )
        #expect(extra.isEmpty)
    }

    @Test("The table list holds tables only")
    func onlyTablesAreTransferable() {
        #expect(DataTransferWizardModel.isTransferable(.table))
        #expect(DataTransferWizardModel.isTransferable(.partitionedTable))
        #expect(!DataTransferWizardModel.isTransferable(.view))
        #expect(!DataTransferWizardModel.isTransferable(.materializedView))
        #expect(!DataTransferWizardModel.isTransferable(.foreignTable))
        #expect(!DataTransferWizardModel.isTransferable(.systemTable))
        #expect(!DataTransferWizardModel.isTransferable(.externalTable))
    }
}
