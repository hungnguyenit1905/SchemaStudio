//
//  CrashReporterConfiguration.swift
//  TablePro
//

import Foundation

struct CrashReporterConfiguration {
    let dsn: String
    let releaseName: String
    let environment: String

    static func resolve(bundle: Bundle = .main) -> CrashReporterConfiguration? {
        guard let dsn = buildSetting(named: "SentryDSN", in: bundle) else { return nil }

        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

        #if DEBUG
        let environment = "debug"
        #else
        let environment = "release"
        #endif

        return CrashReporterConfiguration(
            dsn: dsn,
            releaseName: "schemastudio@\(shortVersion)+\(build)",
            environment: environment
        )
    }

    private static func buildSetting(named key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }
}
