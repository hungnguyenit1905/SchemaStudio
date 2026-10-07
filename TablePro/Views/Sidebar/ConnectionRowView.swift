//
//  ConnectionRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionRowView: View {
    let connection: DatabaseConnection
    let status: ConnectionStatus
    let isEmphasized: Bool
    var failureMessage: String?
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(connection.name)
                .fontWeight(status.isConnected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(nameStyle)

            Spacer(minLength: 4)

            if case .connecting = status {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }

            if let failureMessage {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.red))
                .help(failureMessage)
                .accessibilityLabel(String(localized: "Retry connecting"))
            }

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityLabel(statusLabel)
        }
    }

    private var nameStyle: AnyShapeStyle {
        if isEmphasized { return AnyShapeStyle(.white) }
        if case .disconnected = status { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }

    private var statusColor: Color {
        if failureMessage != nil { return .red }
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .error: return .red
        }
    }

    private var statusLabel: String {
        if failureMessage != nil { return String(localized: "Connection error") }
        switch status {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting")
        case .disconnected: return String(localized: "Disconnected")
        case .error: return String(localized: "Connection error")
        }
    }
}

struct ConnectionFolderRowView: View {
    let group: ConnectionGroup
    let isEmphasized: Bool

    var body: some View {
        Label {
            Text(group.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder")
        }
        .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(folderTint))
    }

    private var folderTint: Color {
        group.color.isDefault ? .secondary : group.color.color
    }
}

struct ConnectionNodeContextMenu: View {
    let connection: DatabaseConnection
    let status: ConnectionStatus
    let isReadOnly: Bool
    var canCreateDatabase = false
    var containerEntityName = String(localized: "Database")
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onNewQuery: () -> Void
    var onNewDatabase: () -> Void = {}

    var body: some View {
        if status.isConnected {
            Button(String(localized: "New Query"), action: onNewQuery)
            if canCreateDatabase {
                Button(String(format: String(localized: "New %@\u{2026}"), containerEntityName), action: onNewDatabase)
                    .disabled(isReadOnly)
            }
            Button(String(localized: "Refresh"), action: onRefresh)
            Divider()
            Button(String(localized: "Close Connection"), action: onDisconnect)
        } else {
            Button(String(localized: "Open Connection"), action: onConnect)
        }
        Divider()
        Button(String(localized: "Edit Connection"), action: onEdit)
    }
}
