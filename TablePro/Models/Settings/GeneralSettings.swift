//
//  GeneralSettings.swift
//  TablePro
//

import Foundation

/// Startup behavior when app launches
enum StartupBehavior: String, Codable, CaseIterable, Identifiable {
    case showWelcome
    case reopenLast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showWelcome: return String(localized: "Show Welcome Screen")
        case .reopenLast: return String(localized: "Reopen Last Session")
        }
    }
}

/// App language options
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english = "en"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case turkish = "tr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .turkish: return "Türkçe"
        }
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// General app settings
struct GeneralSettings: Codable, Equatable {
    var startupBehavior: StartupBehavior
    var language: AppLanguage

    /// Query execution timeout in seconds (0 = no limit)
    var queryTimeoutSeconds: Int

    /// Whether to share anonymous usage analytics
    var shareAnalytics: Bool

    /// Whether to send anonymous crash reports
    var crashReporting: Bool

    /// Whether the sidebar shows a Recent section with recently opened tables
    var showRecentTables: Bool

    /// Whether to show database object comments in the sidebar and data grid headers
    var showObjectComments: Bool

    var showHiddenItems: Bool

    static let `default` = GeneralSettings(
        startupBehavior: .reopenLast,
        language: .system,
        queryTimeoutSeconds: 60,
        shareAnalytics: false,
        crashReporting: false,
        showRecentTables: false,
        showObjectComments: true,
        showHiddenItems: false
    )

    init(
        startupBehavior: StartupBehavior = .reopenLast,
        language: AppLanguage = .system,
        queryTimeoutSeconds: Int = 60,
        shareAnalytics: Bool = false,
        crashReporting: Bool = false,
        showRecentTables: Bool = false,
        showObjectComments: Bool = true,
        showHiddenItems: Bool = false
    ) {
        self.startupBehavior = startupBehavior
        self.language = language
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.shareAnalytics = shareAnalytics
        self.crashReporting = crashReporting
        self.showRecentTables = showRecentTables
        self.showObjectComments = showObjectComments
        self.showHiddenItems = showHiddenItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startupBehavior = try container.decode(StartupBehavior.self, forKey: .startupBehavior)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        queryTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .queryTimeoutSeconds) ?? 60
        shareAnalytics = try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics) ?? false
        crashReporting = try container.decodeIfPresent(Bool.self, forKey: .crashReporting) ?? false
        showRecentTables = try container.decodeIfPresent(Bool.self, forKey: .showRecentTables) ?? false
        showObjectComments = try container.decodeIfPresent(Bool.self, forKey: .showObjectComments) ?? true
        showHiddenItems = try container.decodeIfPresent(Bool.self, forKey: .showHiddenItems) ?? false
    }
}
