//
//  CrashReporterService.swift
//  TablePro
//

import Foundation
import TableProDiagnostics

/// The app's single entry point for crash reporting. Chokepoints report through
/// `CrashReporterService.shared.capture(_:)` and never touch the SDK directly.
@MainActor
final class CrashReporterService {
    static let shared = CrashReporterService()

    private let reporter: CrashReporting

    init(reporter: CrashReporting = CrashReporterFactory.make()) {
        self.reporter = reporter
    }

    func startIfEnabled() {
        guard AppSettingsStorage.shared.loadGeneral().crashReporting else { return }
        reporter.start()
    }

    func applyConsentChange(isEnabled: Bool) {
        if isEnabled {
            reporter.start()
        } else {
            reporter.stop()
        }
    }

    func capture(_ event: DiagnosticEvent) {
        reporter.capture(event)
    }
}
