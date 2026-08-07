//
//  TabRoutingTests.swift
//  TableProTests
//
//  The sidebar spans every saved connection, so a click can name a connection
//  the window is not bound to. These pin the three rules that split apart:
//  which open path runs, which tab group the new window joins, and which
//  coordinator the bottom bar acts through.
//

import Foundation
import Testing

@testable import SchemaStudio

@Suite("Tab routing")
@MainActor
struct TabRoutingTests {
    // MARK: - Open path

    @Test("A node under the window's own connection keeps the coordinator path")
    func sameConnectionUsesCoordinator() {
        let connectionId = UUID()

        let route = SidebarTabRouter.route(
            nodeConnectionId: connectionId, windowConnectionId: connectionId
        )

        #expect(route == .currentWindowCoordinator)
    }

    @Test("A node under another connection opens a tab bound to that connection")
    func otherConnectionOpensNewTab() {
        let route = SidebarTabRouter.route(
            nodeConnectionId: UUID(), windowConnectionId: UUID()
        )

        #expect(route == .newTabForNodeConnection)
    }

    // MARK: - Tab group

    @Test("A shared policy ignores the connection so every tab lands in one group")
    func sharedPolicyIsConnectionIndependent() {
        let idA = WindowManager.tabbingIdentifier(for: UUID(), policy: .shared)
        let idB = WindowManager.tabbingIdentifier(for: UUID(), policy: .shared)

        #expect(idA == "com.SchemaStudio.main")
        #expect(idA == idB)
    }

    @Test("A per-connection policy gives each connection its own group")
    func perConnectionPolicySplitsGroups() {
        let connectionId = UUID()

        let identifier = WindowManager.tabbingIdentifier(for: connectionId, policy: .perConnection)

        #expect(identifier == "com.SchemaStudio.main.\(connectionId.uuidString)")
        #expect(identifier != WindowManager.tabbingIdentifier(for: UUID(), policy: .perConnection))
    }

    @Test("The settings policy still drives every path that does not force a group")
    func settingsPolicyFollowsTheSetting() {
        let original = AppSettingsManager.shared.tabs.groupAllConnectionTabs
        defer { AppSettingsManager.shared.tabs.groupAllConnectionTabs = original }

        AppSettingsManager.shared.tabs.groupAllConnectionTabs = true
        #expect(TabGroupPolicy.fromSettings == .shared)

        AppSettingsManager.shared.tabs.groupAllConnectionTabs = false
        #expect(TabGroupPolicy.fromSettings == .perConnection)
    }

    @Test("Forcing the shared group does not depend on the setting")
    func forcedSharedGroupIgnoresTheSetting() {
        let original = AppSettingsManager.shared.tabs.groupAllConnectionTabs
        defer { AppSettingsManager.shared.tabs.groupAllConnectionTabs = original }
        AppSettingsManager.shared.tabs.groupAllConnectionTabs = false

        let identifier = WindowManager.tabbingIdentifier(for: UUID(), policy: .shared)

        #expect(identifier == "com.SchemaStudio.main")
    }

    // MARK: - Which tab group a new tab joins

    /// `NSApp.windows` is roughly creation order, so picking its first match
    /// puts a sidebar-opened tab in whichever group happened to be made first
    /// rather than the one the user clicked in.
    @Test("The window the tab was opened from wins over every other candidate")
    func anchorWinsTheTabGroup() {
        let chosen = TabGroupSiblingPolicy.choose(
            anchor: "anchor", keyWindow: "key", mainWindow: "main", frontToBack: ["oldest", "newest"]
        ) { _ in true }

        #expect(chosen == "anchor")
    }

    @Test("Without an anchor the focused window decides, not creation order")
    func keyWindowIsTheFallback() {
        let chosen = TabGroupSiblingPolicy.choose(
            anchor: nil, keyWindow: "key", mainWindow: "main", frontToBack: ["oldest", "newest"]
        ) { _ in true }

        #expect(chosen == "key")
    }

    @Test("An anchor that cannot host the tab is skipped for the next best window")
    func unusableAnchorFallsThrough() {
        let chosen = TabGroupSiblingPolicy.choose(
            anchor: "closed", keyWindow: "key", mainWindow: "main", frontToBack: ["oldest"]
        ) { $0 != "closed" }

        #expect(chosen == "key")
    }

    @Test("With no anchor, key or main window the frontmost match wins over the oldest")
    func frontToBackIsTheLastResort() {
        let chosen = TabGroupSiblingPolicy.choose(
            anchor: nil, keyWindow: nil, mainWindow: nil, frontToBack: ["frontmost", "behind"]
        ) { _ in true }

        #expect(chosen == "frontmost")
    }

    @Test("No candidate can host the tab, so it opens standalone")
    func noSiblingOpensStandalone() {
        let chosen = TabGroupSiblingPolicy.choose(
            anchor: "a", keyWindow: "b", mainWindow: "c", frontToBack: ["d"]
        ) { _ in false }

        #expect(chosen == nil)
    }

    // MARK: - Coordinator resolution

    @Test("The key window's coordinator wins when it holds the selected connection")
    func keyWindowCoordinatorWins() {
        let target = UUID()

        let choice = SidebarCoordinatorResolver.choice(
            target: target, keyWindowConnectionId: target, hostConnectionId: target
        )

        #expect(choice == .keyWindow)
    }

    @Test("The sidebar's own window is the fallback when the key window is elsewhere")
    func hostCoordinatorIsTheFallback() {
        let target = UUID()

        let choice = SidebarCoordinatorResolver.choice(
            target: target, keyWindowConnectionId: UUID(), hostConnectionId: target
        )

        #expect(choice == .host)
    }

    @Test("No coordinator resolves when neither window holds the selected connection")
    func noCoordinatorLeavesTheBarDisabled() {
        let choice = SidebarCoordinatorResolver.choice(
            target: UUID(), keyWindowConnectionId: UUID(), hostConnectionId: UUID()
        )

        #expect(choice == .none)
    }

    @Test("A connection with several windows still resolves to one named coordinator")
    func multipleWindowsPerConnectionStayDeterministic() {
        let target = UUID()

        // Both windows belong to the same connection, which is exactly the case
        // where picking out of the instance-keyed registry would be arbitrary.
        let repeated = (0 ..< 20).map { _ in
            SidebarCoordinatorResolver.choice(
                target: target, keyWindowConnectionId: target, hostConnectionId: target
            )
        }

        #expect(repeated.allSatisfy { $0 == .keyWindow })
    }

    @Test("Selecting nothing yet leaves the window's own connection in charge")
    func absentSelectionFallsBackToTheWindow() {
        let windowConnectionId = UUID()
        let selected: UUID? = nil

        let target = selected ?? windowConnectionId

        #expect(
            SidebarCoordinatorResolver.choice(
                target: target, keyWindowConnectionId: nil, hostConnectionId: windowConnectionId
            ) == .host
        )
    }
}
