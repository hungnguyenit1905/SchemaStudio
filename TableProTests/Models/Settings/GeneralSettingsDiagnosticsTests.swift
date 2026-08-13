//
//  GeneralSettingsDiagnosticsTests.swift
//  TableProTests
//

import Foundation
import TableProDiagnostics
import Testing

@testable import SchemaStudio

@Suite("GeneralSettings diagnostics consent")
struct GeneralSettingsDiagnosticsTests {
    @Test("Both diagnostics toggles are off by default")
    func defaultsAreOff() {
        #expect(GeneralSettings.default.crashReporting == false)
        #expect(GeneralSettings.default.shareAnalytics == false)
    }

    @Test("Settings saved before the toggles existed decode as off, never as consent")
    func missingKeysDecodeAsOff() throws {
        let json = Data(#"{"startupBehavior":"reopenLast"}"#.utf8)
        let settings = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(settings.crashReporting == false)
        #expect(settings.shareAnalytics == false)
    }

    @Test("An explicit choice survives a round trip")
    func explicitChoiceRoundTrips() throws {
        let json = Data(#"{"startupBehavior":"reopenLast","crashReporting":true,"shareAnalytics":true}"#.utf8)
        let settings = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(settings.crashReporting)
        #expect(settings.shareAnalytics)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: encoded)

        #expect(decoded.crashReporting)
        #expect(decoded.shareAnalytics)
    }
}

@Suite("CrashReporterFactory")
struct CrashReporterFactoryTests {
    private static let configuration = CrashReporterConfiguration(
        dsn: "https://key@o0.ingest.sentry.io/0",
        releaseName: "schemastudio@1.0.0",
        distribution: "1",
        environment: "debug"
    )

    @Test("Reports nothing when the app has no DSN built in")
    func noReporterWithoutDsn() {
        let reporter = CrashReporterFactory.make(
            isUITesting: false,
            configuration: nil,
            machineId: "machine",
            isEnabled: { true }
        )

        #expect(reporter is NoopCrashReporter)
    }

    @Test("Reports nothing under UI tests, so an automated run never reaches Sentry")
    func noReporterUnderUITests() {
        let reporter = CrashReporterFactory.make(
            isUITesting: true,
            configuration: Self.configuration,
            machineId: "machine",
            isEnabled: { true }
        )

        #expect(reporter is NoopCrashReporter)
    }

    @Test("Builds the real reporter once a DSN is present")
    func buildsSentryReporter() {
        let reporter = CrashReporterFactory.make(
            isUITesting: false,
            configuration: Self.configuration,
            machineId: "machine",
            isEnabled: { true }
        )

        #expect(reporter is SentryCrashReporter)
    }
}
