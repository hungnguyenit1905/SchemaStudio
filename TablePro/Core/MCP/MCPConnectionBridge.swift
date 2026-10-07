import Foundation
import os
import TableProPluginKit

public actor MCPConnectionBridge {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "MCPConnectionBridge")

    private var defaultDatabases: [UUID: String] = [:]
    private var defaultSchemas: [UUID: String] = [:]

    public init() {}

    func defaultScope(connectionId: UUID) -> (database: String?, schema: String?) {
        (defaultDatabases[connectionId], defaultSchemas[connectionId])
    }

    func listConnections() async -> JsonValue {
        let (connections, activeSessions) = await MainActor.run {
            let conns = ConnectionStorage.shared.loadConnections()
                .filter { $0.externalAccess != .blocked }
            let sessions = DatabaseManager.shared.activeSessions
            return (conns, sessions)
        }

        let items: [JsonValue] = connections.map { conn in
            let session = activeSessions[conn.id]
            let isConnected = session?.status.isConnected ?? false
            let policy = conn.aiPolicy ?? AIConnectionPolicy.askEachTime

            return .object([
                "id": .string(conn.id.uuidString),
                "name": .string(conn.name),
                "type": .string(conn.type.rawValue),
                "host": .string(conn.host),
                "port": .int(conn.port),
                "database": .string(session?.resolvedBrowseDatabase ?? conn.database),
                "username": .string(conn.username),
                "is_connected": .bool(isConnected),
                "ai_policy": .string(policy.rawValue),
                "safe_mode": .string(conn.safeModeLevel.rawValue)
            ])
        }

        return .object(["connections": .array(items)])
    }

    func connect(connectionId: UUID) async throws -> JsonValue {
        let connection = try await resolveConnection(connectionId)

        let existingSession = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId]
        }

        if let existing = existingSession, existing.driver != nil {
            let serverVersion = existing.driver?.serverVersion
            let mcpDefault = defaultScope(connectionId: connectionId)
            let currentDatabase = mcpDefault.database ?? existing.resolvedBrowseDatabase
            let currentSchema = mcpDefault.database == nil ? existing.browseSchema : mcpDefault.schema

            var result: [String: JsonValue] = [
                "status": "connected",
                "current_database": .string(currentDatabase)
            ]
            if let version = serverVersion {
                result["server_version"] = .string(version)
            }
            if let schema = currentSchema {
                result["current_schema"] = .string(schema)
            }
            return .object(result)
        }

        try await DatabaseManager.shared.ensureConnected(connection)

        let (serverVersion, currentDatabase, currentSchema) = await MainActor.run {
            let session = DatabaseManager.shared.activeSessions[connectionId]
            return (
                session?.driver?.serverVersion,
                session?.resolvedBrowseDatabase,
                session?.browseSchema
            )
        }

        var result: [String: JsonValue] = [
            "status": "connected",
            "current_database": .string(currentDatabase ?? "")
        ]
        if let version = serverVersion {
            result["server_version"] = .string(version)
        }
        if let schema = currentSchema {
            result["current_schema"] = .string(schema)
        }

        return .object(result)
    }

    func disconnect(connectionId: UUID) async throws {
        let sessionExists = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId] != nil
        }
        guard sessionExists else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        defaultDatabases.removeValue(forKey: connectionId)
        defaultSchemas.removeValue(forKey: connectionId)
        await DatabaseManager.shared.disconnectSession(connectionId)
    }

    func getConnectionStatus(connectionId: UUID) async throws -> JsonValue {
        let core = await MainActor.run {
            () -> (status: ConnectionStatus, database: String, schema: String?)? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else {
                return nil
            }
            return (session.status, session.resolvedBrowseDatabase, session.browseSchema)
        }

        guard let core else {
            throw MCPDataLayerError.notConnected(connectionId)
        }

        let meta = await MainActor.run {
            () -> (version: String?, connectedAt: Date, lastActiveAt: Date) in
            let session = DatabaseManager.shared.activeSessions[connectionId]
            return (
                session?.driver?.serverVersion,
                session?.connectedAt ?? Date(),
                session?.lastActiveAt ?? Date()
            )
        }

        let statusString: String
        var errorDetail: JsonValue?
        switch core.status {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnected: statusString = "disconnected"
        case .error(let msg):
            statusString = "error"
            errorDetail = .object([
                "message": .string(msg)
            ])
        }

        let mcpDefault = defaultScope(connectionId: connectionId)
        var result: [String: JsonValue] = [
            "status": .string(statusString),
            "current_database": .string(mcpDefault.database ?? core.database),
            "connected_at": .string(ISO8601DateFormatter().string(from: meta.connectedAt)),
            "last_active_at": .string(ISO8601DateFormatter().string(from: meta.lastActiveAt))
        ]
        if let schema = mcpDefault.database == nil ? core.schema : mcpDefault.schema {
            result["current_schema"] = .string(schema)
        }
        if let version = meta.version {
            result["server_version"] = .string(version)
        }
        if let errorDetail {
            result["error"] = errorDetail
        }

        return .object(result)
    }

    /// The scope a tool operates on. A tool that names a database gets that database; one that
    /// does not gets the MCP default set by `switch_database`, then the connection's default.
    /// None of them changes the user's sidebar or the database their new tabs open in.
    func resolveScope(connectionId: UUID, database: String?, schema: String?) async throws -> DatabaseScope {
        try await ensureConnected(connectionId)
        let requestedDatabase = database.flatMap { $0.isEmpty ? nil : $0 }
        let mcpDatabase = defaultDatabases[connectionId]
        let resolvedDatabase = requestedDatabase ?? mcpDatabase
        let usesMCPDefault = requestedDatabase == nil || requestedDatabase == mcpDatabase
        let resolvedSchema = schema.flatMap { $0.isEmpty ? nil : $0 }
            ?? (usesMCPDefault ? defaultSchemas[connectionId] : nil)
        return try await MainActor.run {
            guard let scope = DatabaseManager.shared.resolvedScope(
                database: resolvedDatabase,
                schema: resolvedSchema,
                for: connectionId
            ) else {
                throw MCPDataLayerError.invalidArgument(
                    "No database to run against. Pass a database name."
                )
            }
            return scope
        }
    }

    func executeQuery(
        scope: DatabaseScope,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int
    ) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        let normalizedQuery = Self.stripTrailingSemicolons(query)
        let isWrite = QueryClassifier.isWriteQuery(normalizedQuery, databaseType: databaseType)
        let hasReturning = normalizedQuery.range(
            of: #"\bRETURNING\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let shouldCap = !isWrite || hasReturning

        let startTime = CFAbsoluteTimeGetCurrent()

        let route = await MainActor.run { DatabaseManager.shared.externalExecutionRoute(for: scope) }
        let result: QueryResult = try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: route
        ) { driver in
            try await withThrowingTaskGroup(of: QueryResult.self) { group in
                group.addTask {
                    if shouldCap {
                        return try await driver.executeUserQuery(
                            query: normalizedQuery,
                            rowCap: maxRows,
                            parameters: nil
                        )
                    }
                    return try await driver.execute(query: normalizedQuery)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    try? driver.cancelQuery()
                    throw MCPDataLayerError.timeout("Query timed out after \(timeoutSeconds) seconds")
                }
                guard let first = try await group.next() else {
                    throw MCPDataLayerError.dataSourceError("No result from query execution")
                }
                group.cancelAll()
                return first
            }
        }

        let executionTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
        let isTruncated = result.isTruncated

        let jsonColumns: [JsonValue] = result.columns.map { .string($0) }
        let jsonRows: [JsonValue] = result.rows.map { row in
            .array(row.map { cell in
                switch cell {
                case .null: return .null
                case .text(let s): return .string(s)
                case .bytes(let d): return .string(d.base64EncodedString())
                case .int(let value): return .int(Int(value))
                case .double(let value): return .double(value)
                case .bool(let value): return .bool(value)
                case .decimalText, .date, .time, .timestamp, .uuid, .array:
                    return .string(cell.textFallback)
                @unknown default: return .string(cell.textFallback)
                }
            })
        }

        var response: [String: JsonValue] = [
            "columns": .array(jsonColumns),
            "rows": .array(jsonRows),
            "row_count": .int(result.rows.count),
            "rows_affected": .int(result.rowsAffected),
            "execution_time_ms": .double(executionTimeMs),
            "is_truncated": .bool(isTruncated)
        ]
        if let statusMessage = result.statusMessage {
            response["status_message"] = .string(statusMessage)
        }

        return .object(response)
    }

    func listTables(scope: DatabaseScope, includeRowCounts: Bool) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)

        let cachedTables = await MainActor.run { () -> [TableInfo] in
            guard DatabaseManager.shared.browseScope(for: scope.connectionId) == scope else { return [] }
            return SchemaService.shared.tables(for: scope.connectionId)
        }

        let tables: [TableInfo]
        if !cachedTables.isEmpty {
            tables = cachedTables
        } else {
            tables = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTables()
            }
        }

        let jsonTables: [JsonValue] = tables.map { table in
            var obj: [String: JsonValue] = [
                "name": .string(table.name),
                "type": .string(table.type.rawValue)
            ]
            if includeRowCounts, let rowCount = table.rowCount {
                obj["row_count"] = .int(rowCount)
            }
            return .object(obj)
        }

        return .object(["tables": .array(jsonTables)])
    }

    func describeTable(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)

        return try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            let columns = try await driver.fetchColumns(table: table, schema: scope.schema)
            let indexes = try await driver.fetchIndexes(table: table)
            let foreignKeys = try await driver.fetchForeignKeys(table: table)
            let approxRowCount = try await driver.fetchApproximateRowCount(table: table)
            let ddl = try? await driver.fetchTableDDL(table: table)

            let jsonColumns: [JsonValue] = columns.map { col in
                var obj: [String: JsonValue] = [
                    "name": .string(col.name),
                    "data_type": .string(col.dataType),
                    "is_nullable": .bool(col.isNullable),
                    "is_primary_key": .bool(col.isPrimaryKey)
                ]
                if let def = col.defaultValue { obj["default_value"] = .string(def) }
                if let extra = col.extra { obj["extra"] = .string(extra) }
                if let comment = col.comment, !comment.isEmpty { obj["comment"] = .string(comment) }
                return .object(obj)
            }

            let jsonIndexes: [JsonValue] = indexes.map { idx in
                .object([
                    "name": .string(idx.name),
                    "columns": .array(idx.columns.map { .string($0) }),
                    "is_unique": .bool(idx.isUnique),
                    "is_primary": .bool(idx.isPrimary),
                    "type": .string(idx.type)
                ])
            }

            let jsonFKs: [JsonValue] = foreignKeys.map { fk in
                var obj: [String: JsonValue] = [
                    "name": .string(fk.name),
                    "column": .string(fk.column),
                    "referenced_table": .string(fk.referencedTable),
                    "referenced_column": .string(fk.referencedColumn),
                    "on_delete": .string(fk.onDelete),
                    "on_update": .string(fk.onUpdate)
                ]
                if let refSchema = fk.referencedSchema {
                    obj["referenced_schema"] = .string(refSchema)
                }
                return .object(obj)
            }

            var result: [String: JsonValue] = [
                "columns": .array(jsonColumns),
                "indexes": .array(jsonIndexes),
                "foreign_keys": .array(jsonFKs)
            ]
            if let ddl {
                result["ddl"] = .string(ddl)
            }
            if let count = approxRowCount {
                result["approximate_row_count"] = .int(count)
            }

            return .object(result)
        }
    }

    func listDatabases(connectionId: UUID) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        let databases = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.fetchDatabases()
        }
        return .object(["databases": .array(databases.map { .string($0) })])
    }

    func listSchemas(scope: DatabaseScope) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSchemas()
        }
        return .object(["schemas": .array(schemas.map { .string($0) })])
    }

    func getTableDDL(scope: DatabaseScope, table: String) async throws -> JsonValue {
        try await ensureConnected(scope.connectionId)
        let ddl = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchTableDDL(table: table)
        }
        return .object(["ddl": .string(ddl)])
    }

    func switchDatabase(connectionId: UUID, database: String) async throws -> JsonValue {
        try await ensureConnected(connectionId)
        let databases = try await DatabaseManager.shared.withBrowseMetadataDriver(connectionId: connectionId) { driver in
            try await driver.fetchDatabases()
        }
        guard databases.contains(database) else {
            throw MCPDataLayerError.invalidArgument("Database '\(database)' does not exist on this connection.")
        }
        defaultDatabases[connectionId] = database
        defaultSchemas.removeValue(forKey: connectionId)
        Self.logger.info("MCP default database set to \(database, privacy: .public) for \(connectionId, privacy: .public)")
        return .object([
            "status": "switched",
            "current_database": .string(database)
        ])
    }

    func switchSchema(connectionId: UUID, schema: String) async throws -> JsonValue {
        let scope = try await resolveScope(connectionId: connectionId, database: nil, schema: nil)
        let schemas = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSchemas()
        }
        guard schemas.contains(schema) else {
            throw MCPDataLayerError.invalidArgument("Schema '\(schema)' does not exist in '\(scope.database)'.")
        }
        defaultDatabases[connectionId] = scope.database
        defaultSchemas[connectionId] = schema
        Self.logger.info("MCP default schema set to \(schema, privacy: .public) for \(connectionId, privacy: .public)")
        return .object([
            "status": "switched",
            "current_schema": .string(schema)
        ])
    }

    /// A resource URI names no database, so the schema resource reports the MCP default scope
    /// set by `switch_database`, or the connection's default database. Reading it off the shared
    /// driver instead would report whichever database a tab last executed against.
    func fetchSchemaResource(connectionId: UUID) async throws -> JsonValue {
        let scope = try await resolveScope(connectionId: connectionId, database: nil, schema: nil)

        let cachedTables = await MainActor.run { () -> [TableInfo] in
            guard DatabaseManager.shared.browseScope(for: connectionId) == scope else { return [] }
            return SchemaService.shared.tables(for: connectionId)
        }

        let tables: [TableInfo]
        if !cachedTables.isEmpty {
            tables = cachedTables
        } else {
            tables = try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                try await driver.fetchTables()
            }
        }

        let limitedTables = Array(tables.prefix(100))

        let tableSchemas: [JsonValue] = try await DatabaseManager.shared.withMetadataDriver(
            scope: scope,
            workload: .bulk
        ) { driver in
            var schemas: [JsonValue] = []
            for table in limitedTables {
                let columns = try await driver.fetchColumns(table: table.name)
                let jsonCols: [JsonValue] = columns.map { col in
                    .object([
                        "name": .string(col.name),
                        "data_type": .string(col.dataType),
                        "is_nullable": .bool(col.isNullable),
                        "is_primary_key": .bool(col.isPrimaryKey)
                    ])
                }
                schemas.append(.object([
                    "name": .string(table.name),
                    "type": .string(table.type.rawValue),
                    "columns": .array(jsonCols)
                ]))
            }
            return schemas
        }

        var result: [String: JsonValue] = ["tables": .array(tableSchemas)]
        if tables.count > 100 {
            result["truncated"] = .bool(true)
            result["total_tables"] = .int(tables.count)
        }

        return .object(result)
    }

    func fetchHistoryResource(
        connectionId: UUID,
        limit: Int,
        search: String?,
        dateFilter: String?
    ) async throws -> JsonValue {
        let filter: DateFilter
        switch dateFilter {
        case "today": filter = .today
        case "thisWeek": filter = .thisWeek
        case "thisMonth": filter = .thisMonth
        default: filter = .all
        }

        let entries = await QueryHistoryManager.shared.fetchHistory(
            limit: limit,
            connectionId: connectionId,
            searchText: search,
            dateFilter: filter
        )

        let jsonEntries: [JsonValue] = entries.map { entry in
            var obj: [String: JsonValue] = [
                "id": .string(entry.id.uuidString),
                "query": .string(entry.query),
                "database_name": .string(entry.databaseName),
                "executed_at": .string(ISO8601DateFormatter().string(from: entry.executedAt)),
                "execution_time_ms": .double(entry.executionTime * 1_000),
                "row_count": .int(entry.rowCount),
                "was_successful": .bool(entry.wasSuccessful)
            ]
            if let errorMsg = entry.errorMessage {
                obj["error_message"] = .string(errorMsg)
            }
            return .object(obj)
        }

        return .object(["history": .array(jsonEntries)])
    }

    private func resolveDriver(_ connectionId: UUID) async throws -> (DatabaseDriver, DatabaseType) {
        let pending: DatabaseConnection? = await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live: return nil
            case .stored(let connection): return connection
            case .unknown: return nil
            }
        }
        if let pending {
            try await connectIfNeeded(pending)
        }
        return try await MainActor.run {
            switch DatabaseManager.shared.connectionState(connectionId) {
            case .live(let driver, let session):
                return (driver, session.connection.type)
            case .stored, .unknown:
                throw MCPDataLayerError.notConnected(connectionId)
            }
        }
    }

    @discardableResult
    private func ensureConnected(_ connectionId: UUID) async throws -> DatabaseType {
        let (_, databaseType) = try await resolveDriver(connectionId)
        return databaseType
    }

    private func connectIfNeeded(_ connection: DatabaseConnection) async throws {
        try await DatabaseManager.shared.ensureConnected(connection)
    }

    private func resolveSession(_ connectionId: UUID) async throws -> ConnectionSession {
        try await MainActor.run {
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else {
                throw MCPDataLayerError.notConnected(connectionId)
            }
            return session
        }
    }

    private func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        try await MainActor.run {
            let connections = ConnectionStorage.shared.loadConnections()
            guard let connection = connections.first(where: { $0.id == connectionId }) else {
                throw MCPDataLayerError.invalidArgument("Connection not found: \(connectionId)")
            }
            return connection
        }
    }

    static func stripTrailingSemicolons(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(";") {
            result = String(result.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
