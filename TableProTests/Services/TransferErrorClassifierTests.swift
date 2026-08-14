import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("TransferErrorClassifier")
struct TransferErrorClassifierTests {
    private struct VendorError: PluginDriverError, Error {
        let message: String
        let code: Int?
        let state: String?

        init(message: String, code: Int? = nil, state: String? = nil) {
            self.message = message
            self.code = code
            self.state = state
        }

        var pluginErrorMessage: String { message }
        var pluginErrorCode: Int? { code }
        var pluginSqlState: String? { state }
    }

    private func postgres(_ state: String, message: String = "query failed") -> VendorError {
        VendorError(message: message, state: state)
    }

    private func mysql(_ code: Int, message: String = "query failed") -> VendorError {
        VendorError(message: message, code: code)
    }

    // MARK: PostgreSQL

    @Test("PostgreSQL deadlock and lock timeouts are retryable")
    func postgresRetryable() {
        #expect(TransferErrorClassifier.classify(postgres("40P01")) == .retryable)
        #expect(TransferErrorClassifier.classify(postgres("40001")) == .retryable)
        #expect(TransferErrorClassifier.classify(postgres("55P03")) == .retryable)
        #expect(TransferErrorClassifier.classify(postgres("08006")) == .retryable)
        #expect(TransferErrorClassifier.classify(postgres("08001")) == .retryable)
        #expect(TransferErrorClassifier.classify(postgres("57P01")) == .retryable)
    }

    @Test("PostgreSQL integrity and data exceptions are constraint violations")
    func postgresConstraintViolations() {
        #expect(TransferErrorClassifier.classify(postgres("23505")) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(postgres("23503")) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(postgres("23502")) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(postgres("22003")) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(postgres("22001")) == .constraintViolation)
    }

    @Test("PostgreSQL permission and syntax errors fail fast")
    func postgresFatal() {
        #expect(TransferErrorClassifier.classify(postgres("42501")) == .fatal)
        #expect(TransferErrorClassifier.classify(postgres("42601")) == .fatal)
        #expect(TransferErrorClassifier.classify(postgres("42P01")) == .fatal)
        #expect(TransferErrorClassifier.classify(postgres("28P01")) == .fatal)
    }

    @Test("PostgreSQL duplicate object states are recognized")
    func postgresDuplicateObject() {
        #expect(TransferErrorClassifier.isDuplicateObject(postgres("42P07")))
        #expect(TransferErrorClassifier.isDuplicateObject(postgres("42710")))
        #expect(TransferErrorClassifier.isDuplicateObject(postgres("42701")))
    }

    // MARK: MySQL

    @Test("MySQL deadlock and lost connection are retryable")
    func mysqlRetryable() {
        #expect(TransferErrorClassifier.classify(mysql(1_213)) == .retryable)
        #expect(TransferErrorClassifier.classify(mysql(1_205)) == .retryable)
        #expect(TransferErrorClassifier.classify(mysql(2_006)) == .retryable)
        #expect(TransferErrorClassifier.classify(mysql(2_013)) == .retryable)
        #expect(TransferErrorClassifier.classify(mysql(1_040)) == .retryable)
    }

    @Test("MySQL duplicate key and data overflow are constraint violations")
    func mysqlConstraintViolations() {
        #expect(TransferErrorClassifier.classify(mysql(1_062)) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(mysql(1_048)) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(mysql(1_264)) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(mysql(1_406)) == .constraintViolation)
        #expect(TransferErrorClassifier.classify(mysql(1_452)) == .constraintViolation)
    }

    @Test("MySQL access and syntax errors fail fast")
    func mysqlFatal() {
        #expect(TransferErrorClassifier.classify(mysql(1_045)) == .fatal)
        #expect(TransferErrorClassifier.classify(mysql(1_064)) == .fatal)
        #expect(TransferErrorClassifier.classify(mysql(1_146)) == .fatal)
    }

    @Test("MySQL duplicate key name is a duplicate object")
    func mysqlDuplicateObject() {
        #expect(TransferErrorClassifier.isDuplicateObject(mysql(1_061)))
        #expect(TransferErrorClassifier.isDuplicateObject(mysql(1_050)))
    }

    // MARK: SQLite (message fallback)

    @Test("SQLite lock messages are retryable")
    func sqliteRetryable() {
        #expect(TransferErrorClassifier.classify(VendorError(message: "database is locked")) == .retryable)
        #expect(TransferErrorClassifier.classify(VendorError(message: "database is busy")) == .retryable)
    }

    @Test("SQLite constraint messages are constraint violations")
    func sqliteConstraint() {
        #expect(
            TransferErrorClassifier.classify(VendorError(message: "UNIQUE constraint failed: users.id"))
                == .constraintViolation
        )
        #expect(
            TransferErrorClassifier.classify(VendorError(message: "FOREIGN KEY constraint failed"))
                == .constraintViolation
        )
    }

    @Test("SQLite missing table is fatal and already-exists is a duplicate object")
    func sqliteFatalAndDuplicate() {
        #expect(TransferErrorClassifier.classify(VendorError(message: "no such table: users")) == .fatal)
        #expect(TransferErrorClassifier.classify(VendorError(message: "no such column: name")) == .fatal)
        #expect(
            TransferErrorClassifier.isDuplicateObject(VendorError(message: "index users_name_idx already exists"))
        )
    }

    // MARK: App-level and unknown

    @Test("cancellation never retries")
    func cancellationIsFatal() {
        #expect(TransferErrorClassifier.classify(CancellationError()) == .fatal)
    }

    @Test("connection failures are retryable, unknown errors are fatal")
    func appLevelErrors() {
        #expect(TransferErrorClassifier.classify(DatabaseError.connectionFailed("down")) == .retryable)
        #expect(TransferErrorClassifier.classify(DatabaseError.notConnected) == .retryable)
        #expect(TransferErrorClassifier.classify(DatabaseError.queryFailed("bad")) == .fatal)
        #expect(TransferErrorClassifier.classify(NSError(domain: "unknown", code: 1)) == .fatal)
    }

    // MARK: Backoff

    @Test("retry delay backs off exponentially")
    func retryDelayGrows() {
        let first = TransferErrorClassifier.retryDelay(afterAttempt: 0)
        let second = TransferErrorClassifier.retryDelay(afterAttempt: 1)
        let third = TransferErrorClassifier.retryDelay(afterAttempt: 2)
        #expect(first < second)
        #expect(second < third)
        #expect(third > 0.9)
    }

    @Test("retry succeeds after transient failures")
    func retrySucceedsAfterTransientFailures() async throws {
        let counter = ActorCounter()
        let value = try await TransferErrorClassifier.withRetry(maxAttempts: 5) {
            let attempt = await counter.next()
            if attempt < 3 { throw mysql(1_213) }
            return attempt
        }
        #expect(value == 3)
    }

    @Test("retry does not retry fatal errors")
    func retryStopsOnFatal() async {
        let counter = ActorCounter()
        do {
            _ = try await TransferErrorClassifier.withRetry(maxAttempts: 5) {
                _ = await counter.next()
                throw mysql(1_064)
            }
            Issue.record("Expected the fatal error to propagate")
        } catch {
            #expect(await counter.count == 1)
        }
    }

    @Test("retry gives up after the attempt limit")
    func retryGivesUp() async {
        let counter = ActorCounter()
        do {
            _ = try await TransferErrorClassifier.withRetry(maxAttempts: 3) {
                _ = await counter.next()
                throw mysql(1_213)
            }
            Issue.record("Expected the transient error to propagate after the limit")
        } catch {
            #expect(await counter.count == 3)
        }
    }
}

private actor ActorCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    var count: Int { value }
}
