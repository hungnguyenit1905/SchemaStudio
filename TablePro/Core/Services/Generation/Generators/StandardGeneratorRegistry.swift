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
        registry.registerBusiness()
        registry.registerAddress()
        registry.registerPerson()
        registry.registerContact()
        registry.registerText()
        registry.registerIntraRow()
        return registry
    }()
}

private extension GeneratorRegistry {
    mutating func registerBusiness() {
        register(CompanyNameGenerator.self)
        register(DepartmentGenerator.self)
        register(ProductNameGenerator.self)
        register(PriceGenerator.self)
        register(CurrencyCodeGenerator.self)
        register(CreditCardNumberGenerator.self)
        register(CreditCardExpiryGenerator.self)
        register(CvvGenerator.self)
        register(IbanGenerator.self)
        register(SwiftCodeGenerator.self)
        register(TaxIdGenerator.self)
        register(SkuGenerator.self)
        register(Ean13Generator.self)
        register(Isbn13Generator.self)
    }
}

private extension GeneratorRegistry {
    mutating func registerAddress() {
        register(LocalityBackedGenerator<CityField>.self)
        register(LocalityBackedGenerator<StateField>.self)
        register(LocalityBackedGenerator<StateCodeField>.self)
        register(LocalityBackedGenerator<PostalCodeField>.self)
        register(LocalityBackedGenerator<CountryField>.self)
        register(LocalityBackedGenerator<CountryCodeField>.self)
        register(LocalityBackedGenerator<LatitudeField>.self)
        register(LocalityBackedGenerator<LongitudeField>.self)
        register(LocalityBackedGenerator<TimeZoneField>.self)
        register(StreetNameGenerator.self)
        register(BuildingNumberGenerator.self)
        register(StreetAddressGenerator.self)
        register(FullAddressGenerator.self)
    }
}

private extension GeneratorRegistry {
    mutating func registerPerson() {
        register(FirstNameGenerator.self)
        register(SimpleWordListGenerator<LastNameField>.self)
        register(SimpleWordListGenerator<JobTitleField>.self)
        register(SimpleWordListGenerator<PersonTitleField>.self)
        register(MiddleNameGenerator.self)
        register(FullNameGenerator.self)
        register(GenderGenerator.self)
        register(AgeGenerator.self)
        register(NationalIdGenerator.self)
    }
}

private extension GeneratorRegistry {
    mutating func registerContact() {
        register(EmailGenerator.self)
        register(UsernameGenerator.self)
        register(PhoneNumberGenerator<LandlineField>.self)
        register(PhoneNumberGenerator<MobileLineField>.self)
        register(DomainGenerator.self)
        register(UrlGenerator.self)
        register(IPv4Generator.self)
        register(IPv6Generator.self)
        register(MacAddressGenerator.self)
    }
}

private extension GeneratorRegistry {
    mutating func registerText() {
        register(LoremSentenceGenerator.self)
        register(LoremParagraphGenerator.self)
        register(LoremTextGenerator.self)
        register(SlugGenerator.self)
        register(ColorGenerator.self)
        register(FileNameGenerator.self)
        register(MimeTypeGenerator.self)
        register(UserAgentGenerator.self)
        register(SemVerGenerator.self)
    }
}

private extension GeneratorRegistry {
    mutating func registerIntraRow() {
        register(ExpressionGenerator.self)
        register(RelativeDateTimeGenerator.self)
        register(SqlQueryGenerator.self)
    }
}
