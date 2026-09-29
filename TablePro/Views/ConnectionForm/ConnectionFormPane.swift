//
//  ConnectionFormPane.swift
//  TablePro
//

import Foundation

enum ConnectionFormPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case ssh
    case cloudflareTunnel
    case cloudSQLProxy
    case socksProxy
    case ssl
    case databases
    case customization
    case advanced
    case aiRules
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .ssh: return String(localized: "SSH Tunnel")
        case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel")
        case .cloudSQLProxy: return String(localized: "Cloud SQL Auth Proxy")
        case .socksProxy: return String(localized: "SOCKS Proxy")
        case .ssl: return String(localized: "SSL/TLS")
        case .databases: return String(localized: "Databases")
        case .customization: return String(localized: "Customization")
        case .advanced: return String(localized: "Advanced")
        case .aiRules: return String(localized: "AI Rules")
        case .diagnostics: return String(localized: "Diagnostics")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "network"
        case .ssh: return "lock.shield"
        case .cloudflareTunnel: return "cloud"
        case .cloudSQLProxy: return "cloud.fill"
        case .socksProxy: return "arrow.triangle.swap"
        case .ssl: return "lock.fill"
        case .databases: return "cylinder.split.1x2"
        case .customization: return "paintbrush"
        case .advanced: return "gearshape.2"
        case .aiRules: return "sparkles"
        case .diagnostics: return "stethoscope"
        }
    }

    @MainActor
    func validationBadge(for coordinator: ConnectionFormCoordinator) -> String? {
        let issues: [String]
        switch self {
        case .general:
            issues = coordinator.network.validationIssues + coordinator.auth.validationIssues
        case .ssh:
            issues = coordinator.ssh.validationIssues
        case .cloudflareTunnel:
            issues = coordinator.cloudflareTunnel.validationIssues
        case .cloudSQLProxy:
            issues = coordinator.cloudSQLProxy.validationIssues
        case .socksProxy:
            issues = coordinator.socksProxy.validationIssues
        case .ssl:
            issues = coordinator.ssl.validationIssues
        case .customization:
            issues = coordinator.customization.validationIssues
        case .advanced:
            issues = coordinator.advanced.validationIssues
        case .aiRules, .databases:
            issues = []
        case .diagnostics:
            issues = coordinator.diagnostics.validationIssues
        }
        return issues.isEmpty ? nil : "exclamationmark.triangle.fill"
    }
}
