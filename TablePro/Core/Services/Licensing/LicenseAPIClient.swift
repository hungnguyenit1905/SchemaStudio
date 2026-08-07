//
//  LicenseAPIClient.swift
//  TablePro
//
//  This fork ships no licensing service. Every entry point fails closed without
//  building a request, so the app stays permanently unlicensed and reaches no host.
//

import Foundation

final class LicenseAPIClient {
    static let shared = LicenseAPIClient()

    private init() {}

    func activate(request: LicenseActivationRequest) async throws -> SignedLicensePayload {
        throw LicenseError.serviceUnavailable
    }

    func acceptInvite(request: LicenseAcceptInviteRequest) async throws -> SignedLicensePayload {
        throw LicenseError.serviceUnavailable
    }

    func validate(request: LicenseValidationRequest) async throws -> SignedLicensePayload {
        throw LicenseError.serviceUnavailable
    }

    func listActivations(licenseKey: String, machineId: String) async throws -> ListActivationsResponse {
        throw LicenseError.serviceUnavailable
    }

    func deactivate(request: LicenseDeactivationRequest) async throws {
        throw LicenseError.serviceUnavailable
    }
}
