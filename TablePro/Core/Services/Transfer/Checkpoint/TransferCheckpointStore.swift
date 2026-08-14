//
//  TransferCheckpointStore.swift
//  TablePro
//

import CryptoKit
import Foundation

/// The resume point of one table's data phase, stored as JSON in Application
/// Support. A checkpoint is written only after the target commit it describes
/// succeeded; a crash between commit and write loses at most one chunk of
/// progress, never data that the target already holds. Mode `copy` never
/// writes a checkpoint: it drops and recreates the table, so resuming
/// mid-table is meaningless and the run always starts over.
actor TransferCheckpointStore {
    struct Entry: Codable, Sendable, Equatable {
        let table: String
        let partition: Int
        let cursor: TransferChunkCursor
        let isComplete: Bool
        let updatedAt: Date

        init(
            table: String,
            partition: Int = 0,
            cursor: TransferChunkCursor,
            isComplete: Bool = false,
            updatedAt: Date = Date()
        ) {
            self.table = table
            self.partition = partition
            self.cursor = cursor
            self.isComplete = isComplete
            self.updatedAt = updatedAt
        }
    }

    static let shared = TransferCheckpointStore()

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    }

    /// A deterministic id for one source/target/mode pair, stable across runs
    /// so a later launch finds the checkpoint the previous run left behind.
    static func jobId(
        source: TransferEndpoint,
        target: TransferEndpoint,
        mode: TransferMode
    ) -> UUID {
        let material = [
            source.connectionId.uuidString,
            source.database,
            source.schema ?? "",
            target.connectionId.uuidString,
            target.database,
            target.schema ?? "",
            mode.rawValue,
        ].joined(separator: "|")
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for index in 0 ..< 16 {
                raw[index] = digest[index]
            }
        }
        return UUID(uuid: bytes)
    }

    func load(jobId: UUID) -> [Entry] {
        let url = fileURL(for: jobId)
        guard let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    func record(jobId: UUID, mode: TransferMode, entry: Entry) {
        guard mode == .emptyThenTransfer else { return }
        var entries = load(jobId: jobId)
        entries.removeAll { $0.table == entry.table && $0.partition == entry.partition }
        entries.append(entry)
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL(for: jobId), options: .atomic)
    }

    func clear(jobId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: jobId))
    }

    private func fileURL(for jobId: UUID) -> URL {
        directory.appendingPathComponent("\(jobId.uuidString).json")
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("SchemaStudio", isDirectory: true)
            .appendingPathComponent("TransferCheckpoints", isDirectory: true)
    }
}
