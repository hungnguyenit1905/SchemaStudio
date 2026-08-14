//
//  CrashReporterFactory.swift
//  TablePro
//

import Foundation
import TableProDiagnostics

enum CrashReporterFactory {
    static func make(
        isUITesting: Bool = ProcessInfo.processInfo.environment["TABLEPRO_UI_TESTING"] == "1",
        configuration: CrashReporterConfiguration? = .resolve(),
        machineId: @autoclosure () -> String = LicenseStorage.shared.machineId,
        isEnabled: @escaping @Sendable () -> Bool = { AppSettingsStorage.shared.loadGeneral().crashReporting }
    ) -> CrashReporting {
        guard !isUITesting, let configuration else { return NoopCrashReporter() }

        return SentryCrashReporter(
            configuration: configuration,
            machineId: machineId(),
            isEnabled: isEnabled
        )
    }
}
