//
//  DatabaseListSettings.swift
//  TablePro
//

import Foundation

struct DatabaseListSettings: Hashable, Sendable {
    var useCustomList: Bool
    var shown: Set<String>
    var autoOpen: Set<String>

    static let empty = DatabaseListSettings(useCustomList: false, shown: [], autoOpen: [])

    init(useCustomList: Bool = false, shown: Set<String> = [], autoOpen: Set<String> = []) {
        self.useCustomList = useCustomList
        self.shown = shown
        self.autoOpen = autoOpen
    }

    var filterSelection: Set<String> {
        useCustomList ? shown : []
    }

    var isEmpty: Bool {
        !useCustomList && shown.isEmpty && autoOpen.isEmpty
    }

    func databasesToAutoOpen(defaultDatabase: String) -> [String] {
        autoOpen
            .filter { !$0.isEmpty && $0 != defaultDatabase }
            .filter { !useCustomList || shown.contains($0) }
            .sorted()
    }
}

extension DatabaseListSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case useCustomList
        case shown
        case autoOpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useCustomList = try container.decodeIfPresent(Bool.self, forKey: .useCustomList) ?? false
        shown = Set(try container.decodeIfPresent([String].self, forKey: .shown) ?? [])
        autoOpen = Set(try container.decodeIfPresent([String].self, forKey: .autoOpen) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(useCustomList, forKey: .useCustomList)
        try container.encode(shown.sorted(), forKey: .shown)
        try container.encode(autoOpen.sorted(), forKey: .autoOpen)
    }
}
