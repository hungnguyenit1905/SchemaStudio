//
//  SentryEventScrubber.swift
//  TablePro
//

import Foundation
import Sentry
import TableProDiagnostics

/// Strips everything the SDK collects on its own before an event leaves the machine.
///
/// `DiagnosticEvent` already makes it impossible for a call site to attach free text,
/// but a crash is assembled by the SDK, not by a call site, so this is the second
/// gate: it keeps the stack trace and drops every field that carries a hostname,
/// a machine name, a message, or a URL.
enum SentryEventScrubber {
    private static let allowedTagKeys: Set<String> = Set(DiagnosticTagKey.allCases.map(\.rawValue))

    static func scrub(_ event: Event, isEnabled: () -> Bool) -> Event? {
        guard isEnabled() else { return nil }

        event.message = nil
        event.breadcrumbs = nil
        event.request = nil
        event.extra = nil
        event.logger = nil
        event.serverName = nil
        event.transaction = nil
        event.tags = event.tags.map { $0.filter { allowedTagKeys.contains($0.key) } }
        event.context = scrubContext(event.context)
        event.exceptions = event.exceptions.map(scrubExceptions)

        return event
    }

    private static func scrubExceptions(_ exceptions: [Exception]) -> [Exception] {
        for exception in exceptions {
            exception.value = ""
        }
        return exceptions
    }

    private static func scrubContext(
        _ context: [String: [String: Any]]?
    ) -> [String: [String: Any]]? {
        guard var context else { return nil }

        for removal in contextRemovals {
            guard var section = context[removal.section] else { continue }
            for key in removal.keys {
                section.removeValue(forKey: key)
            }
            context[removal.section] = section
        }
        return context
    }

    private static let contextRemovals: [(section: String, keys: [String])] = [
        ("device", ["name", "device_unique_identifier"]),
        ("app", ["app_name", "device_app_hash"]),
        ("culture", ["timezone"])
    ]
}
