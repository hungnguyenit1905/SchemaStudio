import Foundation
@testable import SchemaStudio
import Testing

@Suite("TransferLoadStrategyResolver")
struct TransferLoadStrategyResolverTests {
    private func resolve(
        bulkWriterAvailable: Bool = true,
        supportsLocalInfile: Bool? = nil,
        localInfileRequired: Bool = false,
        continueOnError: Bool = false
    ) -> (TransferLoadStrategy, TransferLoadFallbackReason?) {
        TransferLoadStrategyResolver.resolve(
            bulkWriterAvailable: bulkWriterAvailable,
            supportsLocalInfile: supportsLocalInfile,
            localInfileRequired: localInfileRequired,
            continueOnError: continueOnError
        )
    }

    @Test("no bulk writer falls back")
    func noBulkWriterFallsBack() {
        let result = resolve(bulkWriterAvailable: false)
        #expect(result.0 == .preparedBatch)
        #expect(result.1 == .noBulkWriter)
    }

    @Test("local infile unknown blocks MySQL bulk")
    func localInfileUnknownBlocksMySQL() {
        let result = resolve(supportsLocalInfile: nil, localInfileRequired: true)
        #expect(result.0 == .preparedBatch)
        #expect(result.1 == .localInfileDisabled)
    }

    @Test("local infile disabled blocks MySQL bulk")
    func localInfileDisabledBlocksMySQL() {
        let result = resolve(supportsLocalInfile: false, localInfileRequired: true)
        #expect(result.0 == .preparedBatch)
        #expect(result.1 == .localInfileDisabled)
    }

    @Test("local infile enabled selects bulk for MySQL")
    func localInfileEnabledSelectsBulk() {
        let result = resolve(supportsLocalInfile: true, localInfileRequired: true)
        #expect(result.0 == .bulk)
        #expect(result.1 == nil)
    }

    @Test("continue on error forces the prepared path")
    func continueOnErrorForcesPrepared() {
        let result = resolve(continueOnError: true)
        #expect(result.0 == .preparedBatch)
        #expect(result.1 == .rowErrorIsolation)
    }

    @Test("non-MySQL vendor ignores local infile and selects bulk")
    func nonMySQLVendorSelectsBulk() {
        let result = resolve(supportsLocalInfile: nil, localInfileRequired: false)
        #expect(result.0 == .bulk)
        #expect(result.1 == nil)
    }
}
