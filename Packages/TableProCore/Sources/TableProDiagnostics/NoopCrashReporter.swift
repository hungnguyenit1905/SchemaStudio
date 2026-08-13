//
//  NoopCrashReporter.swift
//  TableProDiagnostics
//

import Foundation

/// Used whenever reporting must not happen: the user has not opted in, no DSN was
/// built into the app, or the app is running under UI tests.
public final class NoopCrashReporter: CrashReporting {
    public init() {}

    public func start() {}

    public func stop() {}

    public func capture(_ event: DiagnosticEvent) {}
}
