//
//  TabBatchClosePlannerDatabaseTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import SchemaStudio
import Testing

@Suite("Tab batch close planner, per database")
@MainActor
struct TabBatchClosePlannerDatabaseTests {
    private let windows = (0 ..< 4).map { _ in NSObject() }

    private func id(_ index: Int) -> ObjectIdentifier {
        ObjectIdentifier(windows[index])
    }

    private var targets: [TabBatchCloseTarget] {
        [
            TabBatchCloseTarget(windowId: id(0), databaseNames: ["app"]),
            TabBatchCloseTarget(windowId: id(1), databaseNames: ["reports"]),
            TabBatchCloseTarget(windowId: id(2), databaseNames: ["reports"]),
            TabBatchCloseTarget(windowId: id(3), databaseNames: ["archive"])
        ]
    }

    @Test("Only windows on the closed database close")
    func closesOnlyThatDatabase() {
        let plan = TabBatchClosePlanner.planCloseForDatabase(
            targets: targets,
            database: "reports",
            currentWindowId: id(0)
        )

        #expect(Set(plan.windowsToCloseOutright) == [id(1), id(2)])
        #expect(plan.survivorWindowId == nil)
    }

    @Test("The window the user is in survives as an empty window")
    func currentWindowSurvives() {
        let plan = TabBatchClosePlanner.planCloseForDatabase(
            targets: targets,
            database: "reports",
            currentWindowId: id(1)
        )

        #expect(plan.windowsToCloseOutright == [id(2)])
        #expect(plan.survivorWindowId == id(1))
    }

    @Test("A database with no tabs closes nothing")
    func databaseWithoutTabsClosesNothing() {
        let plan = TabBatchClosePlanner.planCloseForDatabase(
            targets: targets,
            database: "billing",
            currentWindowId: id(0)
        )

        #expect(plan.isEmpty)
    }

    @Test("An empty database name closes nothing")
    func emptyNameClosesNothing() {
        #expect(TabBatchClosePlanner.planCloseForDatabase(targets: targets, database: "", currentWindowId: nil).isEmpty)
    }

    @Test("Closing a connection closes all of its windows and keeps the current one")
    func connectionCloseKeepsCurrentWindow() {
        let plan = TabBatchClosePlanner.planCloseForConnection(targets: targets, currentWindowId: id(3))

        #expect(Set(plan.windowsToCloseOutright) == [id(0), id(1), id(2)])
        #expect(plan.survivorWindowId == id(3))
    }

    @Test("Closing a connection from another window closes every window of it")
    func connectionCloseFromElsewhere() {
        let plan = TabBatchClosePlanner.planCloseForConnection(targets: targets, currentWindowId: nil)

        #expect(plan.windowsToCloseOutright.count == 4)
        #expect(plan.survivorWindowId == nil)
    }
}
