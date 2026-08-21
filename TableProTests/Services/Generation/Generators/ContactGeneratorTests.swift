//
//  ContactGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The contact group has to stay unable to reach anyone. Addresses use reserved
/// domains, US numbers use the fictional `555-01xx` block, hosts use reserved
/// top-level domains, and network addresses come from documentation or private
/// ranges. These assert that, alongside the shape of each value and the
/// `distinctValueCount` pre-flight trusts.
@Suite("Contact generators")
struct ContactGeneratorTests {
    private static let registry = GeneratorRegistry.standard

    private func generator(
        _ identifier: String,
        params: String = "{}",
        dataType: String = "text"
    ) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(dataType: dataType),
            seed: 31
        )
    }

    private func produced(_ generator: any ValueGenerator, draws: Int) throws -> [String] {
        try (0..<draws).compactMap { index in
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .text(text) = value else { return nil }
            return text
        }
    }

    private func words(_ dataset: GenerationDataset, _ locale: GenerationLocale) throws -> [String] {
        try LocaleWordSource(dataset, locale: locale, generator: "test").words
    }

    // MARK: - Folding

    @Test("Vietnamese letters fold to the ASCII a handle can hold")
    func vietnameseFoldsToAscii() {
        #expect(AsciiSlug.joined("Nguyễn", separator: "") == "nguyen")
        #expect(AsciiSlug.joined("Đồng Tâm", separator: ".") == "dong.tam")
        #expect(AsciiSlug.joined("Trần Thị Hương", separator: "_") == "tran_thi_huong")
        #expect(AsciiSlug.words("O'Brien-Smith") == ["o", "brien", "smith"])
        #expect(AsciiSlug.words("   ").isEmpty)
    }

    // MARK: - Email

    @Test("Addresses use only domains that can never receive mail", arguments: GenerationLocale.allCases)
    func addressesUseReservedDomains(locale: GenerationLocale) throws {
        let reserved = Set(try words(.emailDomains, locale))
        let email = try generator("Email", params: #"{"locale":"\#(locale.rawValue)"}"#)
        for address in try produced(email, draws: 500) {
            let parts = address.split(separator: "@").map(String.init)
            #expect(parts.count == 2)
            #expect(reserved.contains(parts[1]))
            #expect(!parts[0].isEmpty)
        }
    }

    @Test("An address carries no letter a mail server cannot route")
    func addressesAreAscii() throws {
        let email = try generator("Email", params: #"{"locale":"vi_VN"}"#)
        let addresses = try produced(email, draws: 1_000)
        #expect(addresses.allSatisfy { $0.allSatisfy { character in character.isASCII } })
        #expect(addresses.contains { $0.contains(".") })
    }

    @Test("Named domains replace the reserved list")
    func namedDomainsWin() throws {
        let email = try generator("Email", params: #"{"locale":"en_US","domains":["corp.internal","Mail.Corp.Internal"]}"#)
        let domains = Set(try produced(email, draws: 400).compactMap { $0.split(separator: "@").last.map(String.init) })
        #expect(domains == ["corp.internal", "mail.corp.internal"])
    }

    @Test("An address never claims more variety than it produces")
    func addressCardinalityHolds() throws {
        let wide = try generator("Email", params: #"{"locale":"en_US"}"#)
        let claimed = try #require(wide.distinctValueCount)
        #expect(claimed >= Set(try produced(wide, draws: 20_000)).count)

        let narrow = try generator("Email", params: #"{"locale":"en_US"}"#, dataType: "varchar(14)")
        let narrowClaim = try #require(narrow.distinctValueCount)
        #expect(narrowClaim < claimed)
        #expect(narrowClaim >= Set(try produced(narrow, draws: 20_000)).count)
    }

    // MARK: - Username

    @Test("The default username style is an initial and a surname")
    func usernameStyleIsAnInitialAndSurname() throws {
        let surnames = Set(try words(.lastNames, .enUS).map { AsciiSlug.joined($0) })
        let username = try generator("Username", params: #"{"locale":"en_US"}"#)
        for handle in try produced(username, draws: 500) {
            #expect(handle.allSatisfy { $0.isASCII })
            #expect(surnames.contains(String(handle.dropFirst())))
        }
    }

    @Test("A numbered username ends in two digits and reports no count")
    func numberedUsernamesReportNoCount() throws {
        let username = try generator("Username", params: #"{"locale":"en_US","style":"nameWithNumber"}"#)
        #expect(username.distinctValueCount == nil)
        #expect(try produced(username, draws: 300).allSatisfy { $0.suffix(2).allSatisfy { $0.isNumber } })
    }

    @Test("Separated styles keep the name and the surname apart", arguments: [
        ("firstDotLast", "."),
        ("firstUnderscoreLast", "_")
    ])
    func separatedStyles(style: String, separator: String) throws {
        let username = try generator("Username", params: #"{"locale":"vi_VN","style":"\#(style)"}"#)
        let handles = try produced(username, draws: 300)
        #expect(handles.allSatisfy { $0.contains(separator) })
        #expect(handles.allSatisfy { $0.allSatisfy { $0.isASCII } })
    }

    // MARK: - Phone numbers

    @Test("US numbers come from the block reserved for fiction", arguments: ["PhoneNumber", "MobileNumber"])
    func usNumbersCannotRing(identifier: String) throws {
        let phone = try generator(identifier, params: #"{"country":"US","writing":"national"}"#)
        let numbers = try produced(phone, draws: 1_000)
        for number in numbers {
            #expect(number.hasPrefix("("))
            #expect(number.contains(") 555-01"))
            #expect(number.count == 14)
        }
        #expect(phone.distinctValueCount == 2_600)
        #expect(Set(numbers).count <= 2_600)
    }

    @Test("US numbers can be written three ways")
    func usWritingStyles() throws {
        let plain = try produced(try generator("PhoneNumber", params: #"{"country":"US","writing":"digits"}"#), draws: 50)
        #expect(plain.allSatisfy { $0.count == 10 && $0.allSatisfy { $0.isNumber } })

        let international = try produced(
            try generator("PhoneNumber", params: #"{"country":"US","writing":"international"}"#),
            draws: 50
        )
        #expect(international.allSatisfy { $0.hasPrefix("+1 ") })
        #expect(international.allSatisfy { $0.split(separator: " ").count == 4 })
    }

    @Test("Vietnamese landlines carry a real area code and eleven digits")
    func vietnameseLandlineShape() throws {
        let areaCodes = ["24", "28", "236", "225", "292", "258", "263", "203"]
        let phone = try generator("PhoneNumber", params: #"{"country":"VN","writing":"digits"}"#)
        for number in try produced(phone, draws: 1_000) {
            #expect(number.count == 11)
            #expect(number.hasPrefix("0"))
            #expect(areaCodes.contains { number.dropFirst().hasPrefix($0) })
        }
    }

    @Test("Vietnamese mobiles carry a real prefix and ten digits")
    func vietnameseMobileShape() throws {
        let phone = try generator("MobileNumber", params: #"{"country":"VN","writing":"digits"}"#)
        for number in try produced(phone, draws: 1_000) {
            #expect(number.count == 10)
            #expect(number.hasPrefix("0"))
            #expect(!number.hasPrefix("00"))
        }
    }

    @Test("Vietnamese numbers are grouped the way they are written down")
    func vietnameseGrouping() throws {
        let mobile = try produced(try generator("MobileNumber", params: #"{"country":"VN"}"#), draws: 200)
        #expect(mobile.allSatisfy { $0.count == 12 })
        #expect(mobile.allSatisfy { $0.split(separator: " ").map(\.count) == [4, 3, 3] })

        let landline = try produced(try generator("PhoneNumber", params: #"{"country":"VN"}"#), draws: 400)
        #expect(landline.allSatisfy { $0.split(separator: " ").count == 3 })
        #expect(landline.contains { $0.split(separator: " ").map(\.count) == [3, 4, 4] })
    }

    @Test("A column too short for a number is refused rather than truncated")
    func shortPhoneColumnsAreRefused() {
        #expect(throws: GenerationError.self) {
            _ = try generator("PhoneNumber", params: #"{"country":"US"}"#, dataType: "varchar(10)")
        }
        #expect(throws: GenerationError.self) {
            _ = try generator("MobileNumber", params: #"{"country":"VN"}"#, dataType: "varchar(8)")
        }
    }

    // MARK: - Network addresses

    @Test("Documentation addresses stay inside the three reserved blocks")
    func documentationAddressesAreReserved() throws {
        let generated = try generator("IPv4")
        #expect(generated.distinctValueCount == 762)
        let addresses = try produced(generated, draws: 20_000)
        for address in addresses {
            let octets = address.split(separator: ".").map(String.init)
            #expect(octets.count == 4)
            let network = octets.prefix(3).joined(separator: ".")
            #expect(["192.0.2", "198.51.100", "203.0.113"].contains(network))
            #expect((1...254).contains(Int(octets[3]) ?? 0))
        }
        #expect(Set(addresses).count == 762)
    }

    @Test("Private addresses stay inside the RFC 1918 ranges")
    func privateAddressesAreReserved() throws {
        let generated = try generator("IPv4", params: #"{"block":"privateNetwork"}"#)
        for address in try produced(generated, draws: 2_000) {
            let octets = address.split(separator: ".").map(String.init)
            let first = Int(octets[0]) ?? 0
            let second = Int(octets[1]) ?? 0
            #expect(first == 10 || (first == 172 && second == 16) || (first == 192 && second == 168))
        }
    }

    @Test("IPv6 addresses come from the documentation prefix")
    func ipv6UsesTheDocumentationPrefix() throws {
        let generated = try generator("IPv6")
        for address in try produced(generated, draws: 500) {
            let groups = address.split(separator: ":").map(String.init)
            #expect(groups.count == 8)
            #expect(groups[0] == "2001" && groups[1] == "0db8")
            #expect(groups.allSatisfy { $0.count == 4 })
        }

        let local = try generator("IPv6", params: #"{"block":"uniqueLocal","uppercase":true}"#)
        let addresses = try produced(local, draws: 200)
        #expect(addresses.allSatisfy { $0.hasPrefix("FD00:") })
        #expect(addresses.allSatisfy { !$0.contains(where: \.isLowercase) })
    }

    @Test("MAC addresses are locally administered, so no real vendor owns them")
    func macAddressesAreLocallyAdministered() throws {
        let generated = try generator("MACAddress")
        for address in try produced(generated, draws: 1_000) {
            let octets = address.split(separator: ":").map(String.init)
            #expect(octets.count == 6)
            let first = try #require(Int(octets[0], radix: 16))
            #expect(first & 0x02 == 0x02)
            #expect(first & 0x01 == 0)
        }
    }

    @Test("MAC addresses can be written three ways")
    func macWritingStyles() throws {
        let hyphenated = try produced(try generator("MACAddress", params: #"{"writing":"hyphens"}"#), draws: 50)
        #expect(hyphenated.allSatisfy { $0.count == 17 && $0.split(separator: "-").count == 6 })

        let dotted = try produced(try generator("MACAddress", params: #"{"writing":"dotted"}"#), draws: 50)
        #expect(dotted.allSatisfy { $0.count == 14 && $0.split(separator: ".").count == 3 })
    }

    @Test("A column too short for an address is refused rather than truncated")
    func shortAddressColumnsAreRefused() {
        #expect(throws: GenerationError.self) {
            _ = try generator("IPv4", dataType: "varchar(8)")
        }
        #expect(throws: GenerationError.self) {
            _ = try generator("IPv6", dataType: "varchar(20)")
        }
        #expect(throws: GenerationError.self) {
            _ = try generator("MACAddress", dataType: "varchar(12)")
        }
    }

    // MARK: - Hosts

    /// Spelled out rather than read off `DomainSource`, so changing that list to
    /// something resolvable fails here instead of quietly agreeing with itself.
    private static let reservedTopLevels: Set<String> = ["test", "example", "invalid"]

    @Test("Hosts use top-level domains that can never resolve")
    func hostsUseReservedTopLevels() throws {
        let domain = try generator("Domain", params: #"{"locale":"vi_VN"}"#)
        let hosts = try produced(domain, draws: 1_000)
        for host in hosts {
            let parts = host.split(separator: ".").map(String.init)
            #expect(parts.count == 2)
            #expect(Self.reservedTopLevels.contains(parts[1]))
            #expect(host.allSatisfy { $0.isASCII })
        }
        let everything = try generator("Domain", params: #"{"locale":"vi_VN"}"#)
        #expect(domain.distinctValueCount == Set(try produced(everything, draws: 20_000)).count)
    }

    @Test("A named top-level domain replaces the reserved ones")
    func namedTopLevelsWin() throws {
        let domain = try generator("Domain", params: #"{"locale":"en_US","topLevels":["co.uk"]}"#)
        #expect(try produced(domain, draws: 200).allSatisfy { $0.hasSuffix(".co.uk") })
    }

    @Test("A URL carries a scheme, a reserved host, and a path")
    func urlShape() throws {
        let url = try generator("URL", params: #"{"locale":"en_US"}"#)
        let addresses = try produced(url, draws: 500)
        for address in addresses {
            #expect(address.hasPrefix("https://"))
            let rest = address.dropFirst("https://".count).split(separator: "/").map(String.init)
            #expect(rest.count == 2)
            #expect(Self.reservedTopLevels.contains(rest[0].split(separator: ".").map(String.init)[1]))
        }
        #expect(try #require(url.distinctValueCount) >= Set(addresses).count)
    }

    @Test("A URL without a path is only a host")
    func urlWithoutPath() throws {
        let url = try generator("URL", params: #"{"locale":"en_US","scheme":"http","includePath":false}"#)
        for address in try produced(url, draws: 200) {
            #expect(address.hasPrefix("http://"))
            #expect(!address.dropFirst("http://".count).contains("/"))
        }
    }
}
