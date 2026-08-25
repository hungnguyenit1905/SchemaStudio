//
//  DuplicateTargetNaming.swift
//  TablePro
//

import Foundation

enum DuplicateTargetNameError: Sendable, Hashable {
    case empty
    case tooLongForVendor(limitBytes: Int)

    var message: String {
        switch self {
        case .empty:
            return String(localized: "Enter a name for the new table.")
        case .tooLongForVendor(let limit):
            return String(
                format: String(localized: "This name is too long. The server allows %d bytes."),
                limit
            )
        }
    }
}

/// Proposes and validates the one name this feature invents. Index and constraint names come from
/// the server, so the byte budget only ever applies here and to the generated sequence name.
///
/// The limit is counted in bytes, not characters: PostgreSQL allows 63 bytes, and a name written
/// in Vietnamese with diacritics spends two or three bytes per character, so it runs out of room
/// far earlier than a character count suggests.
enum DuplicateTargetNaming {
    /// `orders` becomes `orders_copy`, then `orders_copy1`, `orders_copy2` until one is free.
    /// `taken` holds every name already in the target schema regardless of kind, because a table
    /// collides with a view, a sequence or an index in the same namespace.
    static func suggestedName(
        source: String,
        taken: Set<String>,
        policy: TransferIdentifierPolicy
    ) -> String {
        let base = policy.shorten("\(source)_copy")
        guard taken.contains(base) else { return base }
        var suffix = 1
        while true {
            let candidate = policy.shorten("\(source)_copy\(suffix)")
            if !taken.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    static func validate(_ name: String, policy: TransferIdentifierPolicy) -> DuplicateTargetNameError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard policy.fits(trimmed) else { return .tooLongForVendor(limitBytes: policy.maxLengthBytes) }
        return nil
    }
}
