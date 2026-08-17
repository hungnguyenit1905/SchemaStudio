//
//  StandardGeneratorRegistry.swift
//  TablePro
//

import Foundation

extension GeneratorRegistry {
    static let standard: GeneratorRegistry = {
        var registry = GeneratorRegistry()
        registry.register(AutoIncrementGenerator.self)
        registry.register(FixedGenerator.self)
        registry.register(ListGenerator.self)
        registry.register(ReferenceGenerator.self)
        registry.register(NullGenerator.self)
        registry.register(DefaultGenerator.self)
        registry.register(CopyGenerator.self)
        registry.register(IntegerGenerator.self)
        registry.register(DecimalGenerator.self)
        registry.register(DoubleGenerator.self)
        registry.register(BooleanGenerator.self)
        registry.register(RandomStringGenerator.self)
        registry.register(RandomBytesGenerator.self)
        registry.register(UuidGenerator.self)
        registry.register(DateGenerator.self)
        registry.register(DateTimeGenerator.self)
        registry.register(LoremWordsGenerator.self)
        return registry
    }()
}
