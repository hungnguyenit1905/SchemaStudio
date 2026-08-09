//
//  PasswordSource.swift
//  TablePro
//

import Foundation
import os

/// Declares where a connection's password comes from when it is not stored in the Keychain.
/// Resolved at connect time from a file, an environment variable, or the stdout of a shell command.
enum PasswordSource: Codable, Hashable, Sendable {
    case file(path: String)
    case env(variable: String)
    case command(shell: String)
    case onePassword(reference: String)
    case vault(path: String, field: String)
    case awsSecretsManager(secretId: String, jsonKey: String?)

    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "PasswordSource")

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case variable
        case shell
        case reference
        case field
        case secretId
        case jsonKey
    }

    private enum Kind: String {
        case file
        case env
        case command
        case onePassword
        case vault
        case awsSecretsManager
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.file.rawValue:
            self = try .file(path: container.decode(String.self, forKey: .path))
        case Kind.env.rawValue:
            self = try .env(variable: container.decode(String.self, forKey: .variable))
        case Kind.command.rawValue:
            self = try .command(shell: container.decode(String.self, forKey: .shell))
        case Kind.onePassword.rawValue:
            self = try .onePassword(reference: container.decode(String.self, forKey: .reference))
        case Kind.vault.rawValue:
            self = try .vault(
                path: container.decode(String.self, forKey: .path),
                field: container.decode(String.self, forKey: .field)
            )
        case Kind.awsSecretsManager.rawValue:
            self = try .awsSecretsManager(
                secretId: container.decode(String.self, forKey: .secretId),
                jsonKey: container.decodeIfPresent(String.self, forKey: .jsonKey)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown passwordSource kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let path):
            try container.encode(Kind.file.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .env(let variable):
            try container.encode(Kind.env.rawValue, forKey: .kind)
            try container.encode(variable, forKey: .variable)
        case .command(let shell):
            try container.encode(Kind.command.rawValue, forKey: .kind)
            try container.encode(shell, forKey: .shell)
        case .onePassword(let reference):
            try container.encode(Kind.onePassword.rawValue, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case .vault(let path, let field):
            try container.encode(Kind.vault.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(field, forKey: .field)
        case .awsSecretsManager(let secretId, let jsonKey):
            try container.encode(Kind.awsSecretsManager.rawValue, forKey: .kind)
            try container.encode(secretId, forKey: .secretId)
            try container.encodeIfPresent(jsonKey, forKey: .jsonKey)
        }
    }

    /// Decodes a password source from a connection container, treating a present-but-malformed
    /// entry as absent so one bad connection cannot fail loading of the whole store.
    static func resilientlyDecoded<Key>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> PasswordSource? {
        do {
            return try container.decodeIfPresent(PasswordSource.self, forKey: key)
        } catch {
            logger.warning("Ignoring malformed passwordSource in a connection")
            return nil
        }
    }
}
