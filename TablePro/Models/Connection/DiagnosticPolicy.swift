import Foundation

struct DiagnosticPolicy: Codable, Equatable, Hashable, Sendable {
    static let disabled = DiagnosticPolicy(isEnabled: false)
    static let minimumStatementTimeoutSeconds = 1
    static let maximumStatementTimeoutSeconds = 60
    static let minimumRunBudgetSeconds = 5
    static let maximumRunBudgetSeconds = 300
    static let minimumStatementLimit = 1
    static let maximumStatementLimit = 20
    static let minimumRowLimit = 1
    static let maximumRowLimit = 10_000
    static let minimumCacheTTLSeconds = 0
    static let maximumCacheTTLSeconds = 86_400

    var isEnabled: Bool
    var statementTimeoutSeconds: Int
    var totalRunBudgetSeconds: Int
    var statementLimit: Int
    var rowLimit: Int
    var cacheTTLSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case statementTimeoutSeconds
        case totalRunBudgetSeconds
        case statementLimit
        case rowLimit
        case cacheTTLSeconds
    }

    init(
        isEnabled: Bool = false,
        statementTimeoutSeconds: Int = 15,
        totalRunBudgetSeconds: Int = 60,
        statementLimit: Int = 12,
        rowLimit: Int = 500,
        cacheTTLSeconds: Int = 900
    ) {
        self.isEnabled = isEnabled
        self.statementTimeoutSeconds = statementTimeoutSeconds
        self.totalRunBudgetSeconds = totalRunBudgetSeconds
        self.statementLimit = statementLimit
        self.rowLimit = rowLimit
        self.cacheTTLSeconds = cacheTTLSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try DiagnosticPolicy(
            isEnabled: container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            statementTimeoutSeconds: container.decodeIfPresent(Int.self, forKey: .statementTimeoutSeconds) ?? 15,
            totalRunBudgetSeconds: container.decodeIfPresent(Int.self, forKey: .totalRunBudgetSeconds) ?? 60,
            statementLimit: container.decodeIfPresent(Int.self, forKey: .statementLimit) ?? 12,
            rowLimit: container.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 500,
            cacheTTLSeconds: container.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) ?? 900
        )
        self = decoded.isValid ? decoded : .disabled
    }

    func encode(to encoder: Encoder) throws {
        let persisted = isValid ? self : .disabled
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(persisted.isEnabled, forKey: .isEnabled)
        try container.encode(persisted.statementTimeoutSeconds, forKey: .statementTimeoutSeconds)
        try container.encode(persisted.totalRunBudgetSeconds, forKey: .totalRunBudgetSeconds)
        try container.encode(persisted.statementLimit, forKey: .statementLimit)
        try container.encode(persisted.rowLimit, forKey: .rowLimit)
        try container.encode(persisted.cacheTTLSeconds, forKey: .cacheTTLSeconds)
    }

    var validationError: String? {
        guard Self.minimumStatementTimeoutSeconds ... Self.maximumStatementTimeoutSeconds ~= statementTimeoutSeconds else {
            return String(localized: "Diagnostic statement timeout must be between 1 and 60 seconds.")
        }
        guard Self.minimumRunBudgetSeconds ... Self.maximumRunBudgetSeconds ~= totalRunBudgetSeconds else {
            return String(localized: "Diagnostic run budget must be between 5 seconds and 5 minutes.")
        }
        guard statementTimeoutSeconds <= totalRunBudgetSeconds else {
            return String(localized: "Diagnostic statement timeout cannot exceed the total run budget.")
        }
        guard Self.minimumStatementLimit ... Self.maximumStatementLimit ~= statementLimit else {
            return String(localized: "Diagnostic statement limit must be between 1 and 20.")
        }
        guard Self.minimumRowLimit ... Self.maximumRowLimit ~= rowLimit else {
            return String(localized: "Diagnostic row limit must be between 1 and 10,000.")
        }
        guard Self.minimumCacheTTLSeconds ... Self.maximumCacheTTLSeconds ~= cacheTTLSeconds else {
            return String(localized: "Diagnostic cache duration must be between 0 seconds and 24 hours.")
        }
        return nil
    }

    var isValid: Bool {
        validationError == nil
    }
}

extension DatabaseType {
    var supportsDatabaseDiagnostics: Bool {
        self == .postgresql || self == .mysql
    }
}
