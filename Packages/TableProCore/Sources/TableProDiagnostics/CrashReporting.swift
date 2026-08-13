//
//  CrashReporting.swift
//  TableProDiagnostics
//

import Foundation

/// The app's view of a crash reporter, kept free of any vendor SDK so this module
/// stays testable and so swapping the backend touches one file in the app target.
public protocol CrashReporting: AnyObject, Sendable {
    func start()
    func stop()
    func capture(_ event: DiagnosticEvent)
}
