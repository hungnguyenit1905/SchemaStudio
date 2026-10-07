//
//  GenerationCheckpoint.swift
//  TablePro
//

import CryptoKit
import Foundation

/// How far one table of a run got, stored as JSON in Application Support. A
/// checkpoint is written only after the batch it describes was accepted, so a
/// crash between the write and the checkpoint re-generates one batch rather
/// than skipping rows.
struct GenerationCheckpoint: Codable, Sendable, Equatable {
    let table: String
    let rowsWritten: Int
    let isComplete: Bool
    let updatedAt: Date

    init(table: String, rowsWritten: Int, isComplete: Bool = false, updatedAt: Date = Date()) {
        self.table = table
        self.rowsWritten = rowsWritten
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }
}

/// The resume points of one run, keyed by a job id derived from the plan itself.
/// A plan the user edited between the interruption and the retry hashes
/// differently, so a resume can never pick up on a run that wrote other data.
actor GenerationCheckpointStore {
    static let shared = GenerationCheckpointStore()

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    }

    /// The connection, database and schema; the seed; every table's shape; and
    /// every column's generator and settings all go into the id. Row counts
    /// included: resuming a 1M-row table into a plan that now asks for 100 rows
    /// would write past the end of what the user asked for. The scope is
    /// included so two databases with identical table shapes and the same seed
    /// never share a checkpoint, and a column's own `params`/`common` are hashed
    /// alongside its generator identifier so editing what a generator does
    /// starts the run over rather than resuming onto rows written under the old
    /// settings.
    static func jobId(for plan: GenerationPlan) -> UUID {
        var material = ["seed:\(plan.seed)"]
        if let scope = plan.scope {
            material.append("connection:\(scope.connectionId.uuidString)")
            material.append("database:\(scope.database)")
            material.append("schema:\(scope.schema ?? "")")
        }
        for table in plan.tables {
            material.append(table.qualifiedName)
            material.append("rows:\(table.rowCount)")
            material.append("empty:\(table.emptyFirst)")
            material.append(table.insertColumns.joined(separator: ","))
            material.append(table.columns.map(Self.columnMaterial).joined(separator: ","))
        }
        return Self.uuid(from: material.joined(separator: "|"))
    }

    private static func columnMaterial(_ column: ColumnPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let paramsDigest = column.params.base64EncodedString()
        let commonDigest = (try? encoder.encode(column.common))?.base64EncodedString() ?? ""
        return "\(column.name)=\(column.generator)|\(paramsDigest)|\(commonDigest)"
    }

    func load(jobId: UUID) -> [GenerationCheckpoint] {
        guard let data = try? Data(contentsOf: fileURL(for: jobId)),
              let entries = try? decoder.decode([GenerationCheckpoint].self, from: data) else {
            return []
        }
        return entries
    }

    func resumePoint(jobId: UUID, table: String) -> GenerationCheckpoint? {
        load(jobId: jobId).first { $0.table == table }
    }

    func record(jobId: UUID, entry: GenerationCheckpoint) {
        var entries = load(jobId: jobId)
        entries.removeAll { $0.table == entry.table }
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

    private static func uuid(from material: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { raw in
            for index in 0 ..< 16 {
                raw[index] = digest[index]
            }
        }
        return UUID(uuid: bytes)
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("SchemaStudio", isDirectory: true)
            .appendingPathComponent("GenerationCheckpoints", isDirectory: true)
    }
}
