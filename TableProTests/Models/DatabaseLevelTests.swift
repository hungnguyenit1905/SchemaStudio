//
//  DatabaseLevelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("Database level")
@MainActor
struct DatabaseLevelTests {
    @Test("Network engines that switch databases have a database level", arguments: [
        DatabaseType.postgresql, .mysql, .mariadb, .mssql, .mongodb, .redshift, .cockroachdb
    ])
    func networkEnginesHaveDatabaseLevel(type: DatabaseType) {
        #expect(DatabaseLevel.live.hasDatabaseLevel(type))
    }

    @Test("File and single-database engines have no database level", arguments: [
        DatabaseType.sqlite, .duckdb, .redis
    ])
    func fileEnginesHaveNoDatabaseLevel(type: DatabaseType) {
        #expect(!DatabaseLevel.live.hasDatabaseLevel(type))
    }

    @Test("A file-based engine has no database level even when it can switch")
    func fileBasedOverridesSwitching() {
        let level = DatabaseLevel(supportsDatabaseSwitching: { _ in true }, connectionMode: { _ in .fileBased })
        #expect(!level.hasDatabaseLevel(.sqlite))
    }

    @Test("A network engine that cannot switch has no database level")
    func noSwitchingMeansNoLevel() {
        let level = DatabaseLevel(supportsDatabaseSwitching: { _ in false }, connectionMode: { _ in .network })
        #expect(!level.hasDatabaseLevel(.oracle))
    }

    @Test("A network engine that can switch has a database level")
    func networkSwitchingHasLevel() {
        let level = DatabaseLevel(supportsDatabaseSwitching: { _ in true }, connectionMode: { _ in .network })
        #expect(level.hasDatabaseLevel(.mysql))
    }
}
