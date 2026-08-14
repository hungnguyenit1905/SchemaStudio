//
//  SentryEventScrubberTests.swift
//  TableProTests
//

import Foundation
import Sentry
import TableProDiagnostics
import Testing

@testable import SchemaStudio

@Suite("SentryEventScrubber")
struct SentryEventScrubberTests {
    private func makeCrashEvent() -> Event {
        let event = Event(level: .fatal)
        event.message = SentryMessage(formatted: "connection to db.internal:5432 failed for user admin")
        event.serverName = "Hungs-MacBook-Pro.local"
        event.logger = "com.SchemaStudio.PostgreSQLDriver"
        event.transaction = "SELECT * FROM customers"
        event.extra = ["query": "SELECT * FROM customers", "host": "db.internal"]
        event.request = SentryRequest()
        event.request?.url = "postgres://admin@db.internal:5432/sales"

        let breadcrumb = Breadcrumb(level: .info, category: "network")
        breadcrumb.message = "GET https://db.internal/health"
        event.breadcrumbs = [breadcrumb]

        let exception = Exception(value: "password authentication failed for user \"admin\"", type: "SIGSEGV")
        exception.stacktrace = SentryStacktrace(frames: [Frame()], registers: [:])
        event.exceptions = [exception]

        event.context = [
            "device": ["name": "Hung's MacBook Pro", "family": "Mac", "arch": "arm64"],
            "app": ["app_name": "SchemaStudio", "app_version": "1.2.0"]
        ]
        event.tags = ["database_type": "postgresql", "host": "db.internal"]

        return event
    }

    @Test("Drops every field that can carry connection or user data")
    func stripsIdentifyingFields() throws {
        let scrubbed = try #require(SentryEventScrubber.scrub(makeCrashEvent(), isEnabled: { true }))

        #expect(scrubbed.message == nil)
        #expect(scrubbed.serverName == nil)
        #expect(scrubbed.logger == nil)
        #expect(scrubbed.transaction == nil)
        #expect(scrubbed.extra == nil)
        #expect(scrubbed.request == nil)
        #expect(scrubbed.breadcrumbs == nil)
    }

    @Test("Keeps the stack trace, which is the whole point of a crash report")
    func keepsStacktrace() throws {
        let scrubbed = try #require(SentryEventScrubber.scrub(makeCrashEvent(), isEnabled: { true }))
        let exception = try #require(scrubbed.exceptions?.first)

        #expect(exception.stacktrace?.frames.isEmpty == false)
        #expect(exception.type == "SIGSEGV")
        #expect(exception.value == "")
    }

    @Test("Removes the machine name from the device context but keeps the hardware facts")
    func stripsDeviceName() throws {
        let scrubbed = try #require(SentryEventScrubber.scrub(makeCrashEvent(), isEnabled: { true }))

        #expect(scrubbed.context?["device"]?["name"] == nil)
        #expect(scrubbed.context?["app"]?["app_name"] == nil)
        #expect(scrubbed.context?["device"]?["arch"] as? String == "arm64")
        #expect(scrubbed.context?["app"]?["app_version"] as? String == "1.2.0")
    }

    @Test("Keeps only tags from the diagnostic vocabulary")
    func filtersTags() throws {
        let scrubbed = try #require(SentryEventScrubber.scrub(makeCrashEvent(), isEnabled: { true }))

        #expect(scrubbed.tags?["database_type"] == "postgresql")
        #expect(scrubbed.tags?["host"] == nil)
    }

    @Test("Sends nothing once consent is withdrawn, even for an already queued event")
    func blocksWhenConsentIsOff() {
        #expect(SentryEventScrubber.scrub(makeCrashEvent(), isEnabled: { false }) == nil)
    }
}
