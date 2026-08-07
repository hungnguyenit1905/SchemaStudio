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

    var body: some View {
        HStack(spacing: 6) {
            connection.type.iconImage
                .renderingMode(.template)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(connection.displayColor))

            Text(connection.name)
                .fontWeight(status.isConnected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(isEmphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))

            Spacer(minLength: 4)

            if case .connecting = status {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityLabel(statusLabel)
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .error: return .red
        }
    }

    private var statusLabel: String {
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
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        if status.isConnected {
            Button(String(localized: "Refresh"), action: onRefresh)
            Divider()
            Button(String(localized: "Disconnect"), action: onDisconnect)
        } else {
            Button(String(localized: "Connect"), action: onConnect)
        }
    }
}
