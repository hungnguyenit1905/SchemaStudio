//
//  MimeTypeCatalog.swift
//  TablePro
//

import Foundation

/// The media types and the file extensions that go with them, in one place so a
/// generated `documents.mime_type` and a generated `documents.file_name` cannot
/// disagree about what a `.pdf` is.
enum MimeTypeCatalog {
    struct Entry: Sendable, Hashable {
        let type: String
        let fileExtension: String

        var category: String { String(type.prefix(while: { $0 != "/" })) }
    }

    static let entries: [Entry] = [
        Entry(type: "image/jpeg", fileExtension: "jpg"),
        Entry(type: "image/png", fileExtension: "png"),
        Entry(type: "image/gif", fileExtension: "gif"),
        Entry(type: "image/webp", fileExtension: "webp"),
        Entry(type: "image/svg+xml", fileExtension: "svg"),
        Entry(type: "image/heic", fileExtension: "heic"),
        Entry(type: "text/plain", fileExtension: "txt"),
        Entry(type: "text/csv", fileExtension: "csv"),
        Entry(type: "text/html", fileExtension: "html"),
        Entry(type: "text/markdown", fileExtension: "md"),
        Entry(type: "application/pdf", fileExtension: "pdf"),
        Entry(type: "application/json", fileExtension: "json"),
        Entry(type: "application/zip", fileExtension: "zip"),
        Entry(type: "application/gzip", fileExtension: "gz"),
        Entry(type: "application/msword", fileExtension: "doc"),
        Entry(type: "application/vnd.ms-excel", fileExtension: "xls"),
        Entry(
            type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            fileExtension: "docx"
        ),
        Entry(
            type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            fileExtension: "xlsx"
        ),
        Entry(type: "audio/mpeg", fileExtension: "mp3"),
        Entry(type: "audio/ogg", fileExtension: "ogg"),
        Entry(type: "audio/wav", fileExtension: "wav"),
        Entry(type: "video/mp4", fileExtension: "mp4"),
        Entry(type: "video/quicktime", fileExtension: "mov"),
        Entry(type: "video/webm", fileExtension: "webm")
    ]

    static let categories: [String] = {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.category) {
            seen.append(entry.category)
        }
        return seen
    }()

    static func types(category: String) -> [String] {
        guard category != "any" else { return entries.map(\.type) }
        return entries.filter { $0.category == category }.map(\.type)
    }

    static func fileExtensions(category: String) -> [String] {
        let matched = category == "any" ? entries : entries.filter { $0.category == category }
        var seen: [String] = []
        for entry in matched where !seen.contains(entry.fileExtension) {
            seen.append(entry.fileExtension)
        }
        return seen
    }
}
