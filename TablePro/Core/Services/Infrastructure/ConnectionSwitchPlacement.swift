//
//  ConnectionSwitchPlacement.swift
//  TablePro
//
//  Where a connection opened from an existing window should land.
//

import Foundation

internal enum ConnectionSwitchPlacement {
    internal static func tabGroup<Window>(anchor: Window?) -> TabGroupPolicy? {
        anchor == nil ? nil : .shared
    }
}
