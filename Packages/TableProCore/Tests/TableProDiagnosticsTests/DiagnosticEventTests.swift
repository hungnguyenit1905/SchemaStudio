//
//  DiagnosticEventTests.swift
//  TableProDiagnosticsTests
//

import Foundation
import Testing

@testable import TableProDiagnostics

@Suite("DiagnosticEvent")
struct DiagnosticEventTests {
    @Test("Sanitizes every tag value at construction, so a leaked message never survives")
    func sanitizesTagsOnInit() {
        let event = DiagnosticEvent(
            id: .connectFailed,
            tags: [
                .databaseType: "postgresql",
                .errorCase: "FATAL: password authentication failed for user \"admin\""
            ]
        )

        #expect(event.tags[.databaseType] == "postgresql")
        #expect(event.tags[.errorCase] == DiagnosticTagValueSanitizer.placeholder)
    }

    @Test("Defaults to error level and no tags")
    func defaults() {
        let event = DiagnosticEvent(id: .pluginLoadFailed)

        #expect(event.level == .error)
        #expect(event.tags.isEmpty)
    }

    @Test("Event and tag identifiers stay stable, because dashboards group on them")
    func rawValuesAreStable() {
        #expect(DiagnosticEventID.connectFailed.rawValue == "connect_failed")
        #expect(DiagnosticEventID.connectCompletedAfterCancel.rawValue == "connect_completed_after_cancel")
        #expect(DiagnosticEventID.pluginLoadFailed.rawValue == "plugin_load_failed")
        #expect(DiagnosticEventID.transferAborted.rawValue == "transfer_aborted")
        #expect(DiagnosticEventID.reconnectExhausted.rawValue == "reconnect_exhausted")

        #expect(DiagnosticTagKey.databaseType.rawValue == "database_type")
        #expect(DiagnosticTagKey.errorCase.rawValue == "error_case")
        #expect(DiagnosticTagKey.driverErrorCode.rawValue == "driver_error_code")
        #expect(DiagnosticTagKey.pluginId.rawValue == "plugin_id")
        #expect(DiagnosticTagKey.pluginKitVersion.rawValue == "plugin_kit_version")
        #expect(DiagnosticTagKey.transferPhase.rawValue == "transfer_phase")
        #expect(DiagnosticTagKey.attemptCount.rawValue == "attempt_count")
    }

    @Test("Every key declares a shape, and no shape admits a dotted hostname")
    func everyKeyHasANarrowShape() {
        for key in DiagnosticTagKey.allCases {
            #expect(!DiagnosticTagValueSanitizer.isValid("db.internal", for: key))
        }
    }
}
