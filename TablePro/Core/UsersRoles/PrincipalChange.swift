import Foundation
import TableProPluginKit

struct PrincipalGrantKey: Hashable {
    let privilege: String
    let scope: PluginPrivilegeScope
}

enum PrincipalChange {
    case create(PluginPrincipalDefinition)
    case alter(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition)
    case setPassword(ref: PluginPrincipalRef, password: String)
    case modifyGrants(PluginPrincipalChangeSet)
    case drop(ref: PluginPrincipalRef, options: PluginPrincipalDropOptions)

    var principal: PluginPrincipalRef {
        switch self {
        case .create(let definition): definition.ref
        case .alter(let old, _): old.ref
        case .setPassword(let ref, _): ref
        case .modifyGrants(let changeSet): changeSet.principal
        case .drop(let ref, _): ref
        }
    }

    var isDestructive: Bool {
        switch self {
        case .drop:
            true
        case .modifyGrants(let changeSet):
            !changeSet.grantsToRemove.isEmpty
        case .create, .alter, .setPassword:
            false
        }
    }

    var executionRank: Int {
        switch self {
        case .create: 0
        case .alter: 1
        case .setPassword: 2
        case .modifyGrants: 3
        case .drop: 4
        }
    }
}

extension PluginPrincipalRef {
    var displayName: String {
        guard let host, !host.isEmpty else { return name }
        return "\(name)@\(host)"
    }
}
