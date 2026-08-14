//
//  SentryCrashReporter.swift
//  TablePro
//

import Foundation
import os
import Sentry
import TableProDiagnostics

/// Every option here is set on purpose. The SDK defaults collect breadcrumbs,
/// network requests, and session data that would carry connection details out of
/// the machine, so the defaults are turned off rather than trusted.
final class SentryCrashReporter: CrashReporting {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "CrashReporter")

    private let configuration: CrashReporterConfiguration
    private let machineId: String
    private let isEnabled: @Sendable () -> Bool

    private let state = OSAllocatedUnfairLock(initialState: false)

    init(
        configuration: CrashReporterConfiguration,
        machineId: String,
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.configuration = configuration
        self.machineId = machineId
        self.isEnabled = isEnabled
    }

    func start() {
        let alreadyStarted = state.withLock { started -> Bool in
            defer { started = true }
            return started
        }
        guard !alreadyStarted else { return }

        let machineId = machineId
        let isEnabled = isEnabled

        SentrySDK.start { options in
            options.dsn = self.configuration.dsn
            options.releaseName = self.configuration.releaseName
            options.dist = self.configuration.distribution
            options.environment = self.configuration.environment

            options.sendDefaultPii = false
            options.maxBreadcrumbs = 0
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.enableAutoSessionTracking = false
            options.enableFileIOTracing = false
            options.enableSwizzling = false
            options.enableMetricKit = false
            options.tracesSampleRate = 0
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 5

            options.beforeSend = { event in
                SentryEventScrubber.scrub(event, isEnabled: isEnabled)
            }

            options.initialScope = { scope in
                let user = User()
                user.userId = machineId
                scope.setUser(user)
                return scope
            }
        }

        Self.logger.info("Crash reporting started")
    }

    func stop() {
        let wasStarted = state.withLock { started -> Bool in
            defer { started = false }
            return started
        }
        guard wasStarted else { return }

        SentrySDK.close()
        Self.logger.info("Crash reporting stopped")
    }

    func capture(_ event: DiagnosticEvent) {
        guard isEnabled(), state.withLock({ $0 }) else { return }

        let sentryEvent = Event(level: event.level.sentryLevel)
        sentryEvent.type = event.id.rawValue
        sentryEvent.fingerprint = [event.id.rawValue]
        sentryEvent.tags = event.tags.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }

        SentrySDK.capture(event: sentryEvent)
    }
}

private extension DiagnosticLevel {
    var sentryLevel: SentryLevel {
        switch self {
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
}
