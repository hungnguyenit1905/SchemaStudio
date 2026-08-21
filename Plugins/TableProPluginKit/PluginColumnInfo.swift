import Foundation

public enum IdentityKind: String, Codable, Sendable, CaseIterable {
    case always = "ALWAYS"
    case byDefault = "BY DEFAULT"
}

public struct PluginColumnInfo: Codable, Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let isPrimaryKey: Bool
    public let defaultValue: String?
    public let extra: String?
    public let charset: String?
    public let collation: String?
    public let comment: String?
    public let identityKind: IdentityKind?
    public let isGenerated: Bool
    public let allowedValues: [String]?

    /// CHECK constraint expressions that restrict this column, verbatim as the
    /// server reports them. A generator has to satisfy them, and there is no
    /// portable way to recover them from the data type alone.
    public let checkExpressions: [String]

    /// Sequence or generator backing this column's default, where the engine
    /// names one. Nil when the default is a literal, an expression, or absent.
    public let sequenceName: String?

    /// Names of the unique constraints and unique indexes this column
    /// participates in. A column in a single-column unique constraint needs
    /// distinct generated values; a column in a composite one does not.
    public let uniqueConstraints: [String]

    public var isIdentity: Bool { identityKind != nil }

    @_disfavoredOverload
    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        identityKind: IdentityKind? = nil,
        isGenerated: Bool = false,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.identityKind = identityKind
        self.isGenerated = isGenerated
        self.allowedValues = allowedValues
        checkExpressions = []
        sequenceName = nil
        uniqueConstraints = []
    }

    public init(
        name: String,
        dataType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        extra: String? = nil,
        charset: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        identityKind: IdentityKind? = nil,
        isGenerated: Bool = false,
        allowedValues: [String]? = nil,
        checkExpressions: [String],
        sequenceName: String? = nil,
        uniqueConstraints: [String] = []
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.charset = charset
        self.collation = collation
        self.comment = comment
        self.identityKind = identityKind
        self.isGenerated = isGenerated
        self.allowedValues = allowedValues
        self.checkExpressions = checkExpressions
        self.sequenceName = sequenceName
        self.uniqueConstraints = uniqueConstraints
    }
}

// Codable is written by hand rather than synthesized. Synthesized `init(from:)`
// calls `decode([String].self, forKey:)` for a non-optional array and throws
// `keyNotFound` when the key is absent, so adding `checkExpressions` and
// `uniqueConstraints` would have made every pre-v20 payload undecodable. The
// fields stay non-optional in the API so no consumer has to tell nil from
// empty, and the empty ones are omitted on encode so a value carrying no
// generation metadata still serializes to exactly the pre-v20 key set.
//
// The cost is that `CodingKeys` and both methods have to be updated by hand
// whenever a field is added. `PluginColumnInfoCodableTests` catches a missed
// decode, and its encoded-key-set assertion catches a missed encode.
extension PluginColumnInfo {
    private enum CodingKeys: String, CodingKey {
        case name
        case dataType
        case isNullable
        case isPrimaryKey
        case defaultValue
        case extra
        case charset
        case collation
        case comment
        case identityKind
        case isGenerated
        case allowedValues
        case checkExpressions
        case sequenceName
        case uniqueConstraints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        dataType = try container.decode(String.self, forKey: .dataType)
        isNullable = try container.decode(Bool.self, forKey: .isNullable)
        isPrimaryKey = try container.decode(Bool.self, forKey: .isPrimaryKey)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        extra = try container.decodeIfPresent(String.self, forKey: .extra)
        charset = try container.decodeIfPresent(String.self, forKey: .charset)
        collation = try container.decodeIfPresent(String.self, forKey: .collation)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        identityKind = try container.decodeIfPresent(IdentityKind.self, forKey: .identityKind)
        isGenerated = try container.decode(Bool.self, forKey: .isGenerated)
        allowedValues = try container.decodeIfPresent([String].self, forKey: .allowedValues)
        checkExpressions = try container.decodeIfPresent([String].self, forKey: .checkExpressions) ?? []
        sequenceName = try container.decodeIfPresent(String.self, forKey: .sequenceName)
        uniqueConstraints = try container.decodeIfPresent([String].self, forKey: .uniqueConstraints) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(dataType, forKey: .dataType)
        try container.encode(isNullable, forKey: .isNullable)
        try container.encode(isPrimaryKey, forKey: .isPrimaryKey)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(extra, forKey: .extra)
        try container.encodeIfPresent(charset, forKey: .charset)
        try container.encodeIfPresent(collation, forKey: .collation)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encodeIfPresent(identityKind, forKey: .identityKind)
        try container.encode(isGenerated, forKey: .isGenerated)
        try container.encodeIfPresent(allowedValues, forKey: .allowedValues)
        if !checkExpressions.isEmpty {
            try container.encode(checkExpressions, forKey: .checkExpressions)
        }
        try container.encodeIfPresent(sequenceName, forKey: .sequenceName)
        if !uniqueConstraints.isEmpty {
            try container.encode(uniqueConstraints, forKey: .uniqueConstraints)
        }
    }
}
