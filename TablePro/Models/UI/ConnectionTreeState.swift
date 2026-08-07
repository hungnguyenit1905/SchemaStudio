//
//  ConnectionTreeState.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
internal final class ConnectionTreeState {
    static let shared = ConnectionTreeState()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoaded = false

    var expandedFolderIds: Set<UUID> = [] { didSet { persist() } }
    var expandedConnectionIds: Set<UUID> = [] { didSet { persist() } }
    var selectedNodeId: String?

    /// Why the last connect attempt for a connection failed. A failed connect
    /// removes its session entry, so `activeSessions` cannot carry the reason;
    /// this is the only place the tree can read it back from. Deliberately not
    /// persisted: a message from a previous launch describes nothing the user
    /// can still act on.
    private(set) var connectFailures: [UUID: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        isLoaded = true
    }

    func recordConnectFailure(_ connectionId: UUID, message: String) {
        connectFailures[connectionId] = message
    }

    func clearConnectFailure(_ connectionId: UUID) {
        connectFailures.removeValue(forKey: connectionId)
    }

    func forget(connectionId: UUID) {
        expandedConnectionIds.remove(connectionId)
        connectFailures.removeValue(forKey: connectionId)
    }

    func forget(folderId: UUID) {
        expandedFolderIds.remove(folderId)
    }

    private struct PersistedTreeState: Codable {
        var folders: [UUID]
        var connections: [UUID]
    }

    private static let storageKey = "com.SchemaStudio.sidebar.connectionTree"

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(PersistedTreeState.self, from: data) else { return }
        expandedFolderIds = Set(decoded.folders)
        expandedConnectionIds = Set(decoded.connections)
    }

    private func persist() {
        guard isLoaded else { return }

        if expandedFolderIds.isEmpty, expandedConnectionIds.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }

        let snapshot = PersistedTreeState(
            folders: Array(expandedFolderIds),
            connections: Array(expandedConnectionIds)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
