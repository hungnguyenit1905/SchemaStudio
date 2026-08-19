//
//  GenerationProfileExporter.swift
//  TablePro
//

import Foundation

/// Reads and writes the shareable form of a profile: the profile itself, with no
/// saved-file id and no timestamp. A profile is generator configuration and
/// nothing else, so an exported file is safe to attach to a bug report. Nothing
/// here strips credentials, because nothing in `GenerationProfile` can hold one:
/// the scope names a connection, it does not describe how to reach one.
enum GenerationProfileExporter {
    static let fileExtension = "json"

    static func export(_ profile: GenerationProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    static func importProfile(from data: Data) throws -> GenerationProfile {
        try JSONDecoder().decode(GenerationProfile.self, from: data)
    }

    static func write(_ profile: GenerationProfile, to url: URL) throws {
        try export(profile).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> GenerationProfile {
        try importProfile(from: Data(contentsOf: url))
    }

    /// A file name that survives a file system: the profile's own name where it
    /// can be used, a fixed fallback where it cannot.
    static func suggestedFileName(for profile: GenerationProfile) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = profile.name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "profile" : cleaned
        return "\(base).\(fileExtension)"
    }
}
