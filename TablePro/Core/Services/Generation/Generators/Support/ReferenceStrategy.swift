//
//  ReferenceStrategy.swift
//  TablePro
//

import Foundation

/// How a column spreads itself over the parent rows it can point at. One
/// vocabulary for both paths: a single-column foreign key drawing through
/// `PoolValuePicker` and a composite one drawing through `ReferencePool` mean
/// the same thing by the same name.
enum ReferenceStrategy: String, Codable, Sendable, CaseIterable {
    case random
    case roundRobin
    case oneToOne
    case ensureCoverage
    case weighted

    var label: String {
        switch self {
        case .random: return String(localized: "At random")
        case .roundRobin: return String(localized: "In turn, round robin")
        case .oneToOne: return String(localized: "One parent row each")
        case .ensureCoverage: return String(localized: "Every parent at least once")
        case .weighted: return String(localized: "Weighted, a few taking most")
        }
    }

    /// True where the strategy draws freely and needs to know nothing about the
    /// run. The other two pair rows with parents, so they need the row count
    /// checked against the pool before the run starts.
    var drawsFreely: Bool {
        self == .random || self == .roundRobin || self == .weighted
    }

    static var freeDrawCases: [ReferenceStrategy] { allCases.filter(\.drawsFreely) }
}
