//
//  DuplicatePreflight.swift
//  TablePro
//

import Foundation

/// Refuses a duplicate before anything is created, so a failure reads as a permission or a naming
/// problem instead of a syntax error partway through a half-built table.
/// What the preflight learned that the run still needs. `targetExists` is only ever true under
/// the `Drop and recreate` policy, because any other policy has already refused.
struct DuplicatePreflightOutcome: Sendable, Hashable {
    let targetExists: Bool
}

struct DuplicatePreflight: Sendable {
    let driver: any DuplicateDriving
    let catalog: any DuplicateVendorCatalog

    func check(
        _ request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection
    ) async throws -> DuplicatePreflightOutcome {
        if let reason = DuplicateTargetNaming.validate(request.targetName, policy: catalog.identifierPolicy) {
            throw DuplicateError.invalidTargetName(reason)
        }

        guard !introspection.isPartitioned else {
            throw DuplicateError.partitionedSource(request.source.name)
        }

        let targetExists = try await checkTargetIsFree(request)
        if let missing = try await catalog.missingPrivilege(request, driver: driver) {
            throw missing
        }
        return DuplicatePreflightOutcome(targetExists: targetExists)
    }

    private func checkTargetIsFree(_ request: DuplicateTableRequest) async throws -> Bool {
        guard try await catalog.targetIsTaken(request, driver: driver) else { return false }
        guard request.options.onExists == .dropAndRecreate else {
            throw DuplicateError.targetExists(request.targetName)
        }
        return true
    }
}
