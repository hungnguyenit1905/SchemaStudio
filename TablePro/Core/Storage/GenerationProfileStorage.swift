//
//  GenerationProfileStorage.swift
//  TablePro
//

import Foundation
import os

/// One saved profile on disk. The id names the file, so renaming a profile
/// rewrites the same file instead of orphaning the old one.
struct SavedGenerationProfile: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var savedAt: Date
    var profile: GenerationProfile

    init(id: UUID = UUID(), savedAt: Date = Date(), profile: GenerationProfile) {
        self.id = id
        self.savedAt = savedAt
        self.profile = profile
    }
}

/// Saved generation profiles, one JSON file each in Application Support. A file
/// per profile rather than one index: a profile that fails to decode costs the
/// user that profile, not the whole list, and export is a copy of a file that
/// already exists.
actor GenerationProfileStorage {
    static let shared = GenerationProfileStorage()

    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "GenerationProfileStorage")

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        let resolved = directory ?? Self.defaultDirectory()
        self.directory = resolved
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    }

    /// Newest first. A file that no longer decodes is skipped and logged rather
    /// than failing the list: one bad profile must not hide the rest.
    func list() -> [SavedGenerationProfile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let saved = try? decoder.decode(SavedGenerationProfile.self, from: data) else {
                    Self.logger.error("Skipped unreadable profile at \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return saved
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func load(id: UUID) -> SavedGenerationProfile? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(SavedGenerationProfile.self, from: data)
    }

    @discardableResult
    func save(_ profile: GenerationProfile, id: UUID = UUID(), at date: Date = Date()) -> SavedGenerationProfile? {
        let saved = SavedGenerationProfile(id: id, savedAt: date, profile: profile)
        do {
            let data = try encoder.encode(saved)
            try data.write(to: fileURL(for: id), options: .atomic)
            return saved
        } catch {
            Self.logger.error("Failed to save generation profile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("SchemaStudio", isDirectory: true)
            .appendingPathComponent("GenerationProfiles", isDirectory: true)
    }
}
