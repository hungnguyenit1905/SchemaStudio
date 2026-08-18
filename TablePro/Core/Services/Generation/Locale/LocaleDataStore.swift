//
//  LocaleDataStore.swift
//  TablePro
//

import Foundation
import os

/// Loads the generation datasets from the app bundle, once per process, and hands
/// out the parsed lines. Every generator that reads a word list goes through here
/// so a run never touches the file system inside its row loop.
///
/// A plain class under a lock rather than an actor: the access pattern is one
/// write and then many reads from the row loop, and an actor hop per lookup would
/// cost more than the load it protects.
final class LocaleDataStore: @unchecked Sendable {
    static let shared = LocaleDataStore()

    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "LocaleDataStore")

    private struct Key: Hashable {
        let locale: GenerationLocale
        let dataset: GenerationDataset
    }

    private let bundle: Bundle
    private let lock = NSLock()
    private var lines: [Key: [String]] = [:]
    private var localities: [GenerationLocale: [LocalityRecord]] = [:]

    init(bundle: Bundle = Bundle(for: LocaleDataStore.self)) {
        self.bundle = bundle
    }

    /// The dataset's lines, or the `en_US` copy when this locale does not carry
    /// one. An empty result means the resource is missing from the bundle, which
    /// is a packaging fault rather than something a caller can recover from, so
    /// it is logged once at load.
    func lines(_ dataset: GenerationDataset, locale: GenerationLocale) -> [String] {
        let key = Key(locale: locale, dataset: dataset)
        lock.lock()
        defer { lock.unlock() }
        if let cached = lines[key] { return cached }
        var loaded = readRawLines(dataset, locale: locale)
        if loaded.isEmpty, locale != .fallback {
            loaded = readRawLines(dataset, locale: .fallback)
        }
        if loaded.isEmpty {
            Self.logger.error("dataset \(dataset.rawValue) missing for \(locale.rawValue)")
        }
        lines[key] = loaded
        return loaded
    }

    func localityRecords(locale: GenerationLocale) -> [LocalityRecord] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = localities[locale] { return cached }
        var parsed = LocalityRecord.parse(readRawLines(.localities, locale: locale))
        if parsed.isEmpty, locale != .fallback {
            parsed = LocalityRecord.parse(readRawLines(.localities, locale: .fallback))
        }
        if parsed.isEmpty {
            Self.logger.error("locality dataset missing for \(locale.rawValue)")
        }
        localities[locale] = parsed
        return parsed
    }

    /// Blank lines and `#` comments are dropped so a dataset file can carry a
    /// provenance header without every generator having to skip it.
    ///
    /// The locale is part of the file name rather than a directory because Xcode
    /// flattens a synchronized group's resources into one `Resources` folder, so
    /// two locales' files would collide on name alone.
    private func readRawLines(_ dataset: GenerationDataset, locale: GenerationLocale) -> [String] {
        guard
            let url = bundle.url(forResource: "\(locale.rawValue)-\(dataset.rawValue)", withExtension: "txt"),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
