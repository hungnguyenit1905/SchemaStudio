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

    @Test("No inbound reference never blocks, regardless of capability")
    func noReferenceClearsRegardlessOfCapability() {
        for capability: PluginConstraintDisableCapability in [.supported, .notPermitted, .notApplicable, .unknown] {
            let outcome = DataTransferService.resolveDropBlock(
                table: "users",
                blocking: [],
                constraintDisable: capability
            )
            #expect(outcome == .clear)
        }
    }

    @Test("A blocking reference warns instead of failing when the target supports disabling checks")
    func blockingReferenceWarnsWhenSupported() {
        let outcome = DataTransferService.resolveDropBlock(
            table: "users",
            blocking: ["orders.orders_user_id_foreign"],
            constraintDisable: .supported
        )
        #expect(outcome == .warned(.externalForeignKeyDropped(table: "users", references: ["orders.orders_user_id_foreign"])))
    }

    @Test("A blocking reference still fails when the target cannot confirm it can disable checks")
    func blockingReferenceStaysBlockedWithoutConfirmedSupport() {
        for capability: PluginConstraintDisableCapability in [.notPermitted, .notApplicable, .unknown] {
            let outcome = DataTransferService.resolveDropBlock(
                table: "users",
                blocking: ["orders.orders_user_id_foreign"],
                constraintDisable: capability
            )
            #expect(outcome == .blocked)
        }
    }

    @Test("The external foreign key warning names the table and every reference")
    func externalForeignKeyWarningMessageIsDescriptive() {
        let message = TransferStructureWarning.externalForeignKeyDropped(
            table: "users",
            references: ["orders.orders_user_id_foreign", "carts.carts_user_id_foreign"]
        ).message
        #expect(message.contains("users"))
        #expect(message.contains("orders.orders_user_id_foreign"))
        #expect(message.contains("carts.carts_user_id_foreign"))
    }
}
