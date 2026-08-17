//
//  GeneratorTestFixtures.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit

enum GeneratorTestFixtures {
    static func column(
        name: String = "value",
        dataType: String = "text",
        isNullable: Bool = true,
        databaseType: DatabaseType = .postgresql,
        allowedValues: [String]? = nil,
        foreignKeys: [PluginForeignKeyInfo] = []
    ) -> GenerationColumn {
        let table = SchemaFactsAssembler(databaseType: databaseType).assemble(
            schema: "public",
            table: "fixture",
            columns: [
                PluginColumnInfo(
                    name: name,
                    dataType: dataType,
                    isNullable: isNullable,
                    allowedValues: allowedValues
                )
            ],
            foreignKeys: foreignKeys,
            indexes: []
        )
        guard let resolved = table.column(named: name) else {
            preconditionFailure("fixture column \(name) missing")
        }
        return resolved
    }

    static func params(_ json: String) -> Data {
        Data(json.utf8)
    }

    /// Parameters every generator accepts, used by the contract suite so a
    /// generator that requires configuration still gets a valid instance.
    static let contractParams: [String: Data] = [
        ListGenerator.identifier: params(#"{"values":["a","b","c"]}"#),
        CopyGenerator.identifier: params(#"{"sourceColumn":"other"}"#),
        ReferenceGenerator.identifier: params(#"{"table":"parent","column":"id"}"#)
    ]

    /// One key of the many each generator accepts. A generator that requires
    /// every key to be present would throw on these.
    static let partialParams: [String: Data] = [
        AutoIncrementGenerator.identifier: params(#"{"start":5}"#),
        ListGenerator.identifier: params(#"{"values":["a","b"]}"#),
        CopyGenerator.identifier: params(#"{"sourceColumn":"other"}"#),
        ReferenceGenerator.identifier: params(#"{"table":"parent","column":"id"}"#),
        IntegerGenerator.identifier: params(#"{"max":9}"#),
        DecimalGenerator.identifier: params(#"{"max":9}"#),
        DoubleGenerator.identifier: params(#"{"max":9}"#),
        BooleanGenerator.identifier: params(#"{"truePercent":10}"#),
        RandomStringGenerator.identifier: params(#"{"maxLength":9}"#),
        RandomBytesGenerator.identifier: params(#"{"maxLength":9}"#),
        UuidGenerator.identifier: params(#"{"uppercase":true}"#),
        DateGenerator.identifier: params(#"{"from":"2020-01-01"}"#),
        DateTimeGenerator.identifier: params(#"{"granularity":"hour"}"#),
        LoremWordsGenerator.identifier: params(#"{"maxWords":4}"#),
        FixedGenerator.identifier: params(#"{"value":"x"}"#)
    ]

    static func rowContext(rowIndex: Int = 0) -> RowContext {
        RowContext(table: "fixture", rowIndex: rowIndex, values: ["other": .text("copied")])
    }

    static func bindPools(_ generator: any ValueGenerator) {
        guard let consumer = generator as? any ReferencePoolConsuming else { return }
        consumer.bind(
            pool: ReferenceValuePool(
                target: consumer.referenceTarget,
                values: [.int(1), .int(2), .int(3)]
            )
        )
    }
}
