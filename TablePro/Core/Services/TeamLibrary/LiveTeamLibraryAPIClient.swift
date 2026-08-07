//
//  LiveTeamLibraryAPIClient.swift
//  TablePro
//
//  This fork ships no team library service. Every entry point fails closed without
//  building a request, so nothing is published to or pulled from a remote host.
//

import Foundation

final class LiveTeamLibraryAPIClient: TeamLibraryAPIClient {
    static let shared = LiveTeamLibraryAPIClient()

    func pull(licenseKey: String, machineId: String) async throws -> TeamLibraryPullResponse {
        throw LicenseError.serviceUnavailable
    }

    func publish(_ request: TeamLibraryPublishRequest) async throws -> TeamLibraryPublishResponse {
        throw LicenseError.serviceUnavailable
    }

    func deleteConnection(id: String, licenseKey: String, machineId: String) async throws {
        throw LicenseError.serviceUnavailable
    }

    func deleteQuery(clientId: String, licenseKey: String, machineId: String) async throws {
        throw LicenseError.serviceUnavailable
    }

    func deleteQueryFolder(clientId: String, licenseKey: String, machineId: String) async throws {
        throw LicenseError.serviceUnavailable
    }
}
