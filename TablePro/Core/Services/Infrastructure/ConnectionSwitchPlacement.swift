//
//  ConnectionSwitchPlacement.swift
//  TablePro
//
//  Where a connection opened from an existing window should land.
//

import AppKit

internal enum ConnectionSwitchPlacement {
    internal static func tabGroup(anchor: NSWindow?) -> TabGroupPolicy? {
        anchor == nil ? nil : .shared
    }
}
