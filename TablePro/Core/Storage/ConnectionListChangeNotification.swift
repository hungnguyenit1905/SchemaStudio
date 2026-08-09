//
//  ConnectionListChangeNotification.swift
//  TablePro
//
//  The saved connection list is read by the welcome window and by the sidebar
//  tree in every editor window. Both need to see an add, an edit, a delete or a
//  folder move without a restart, and neither owns the data.
//
//  Posted by the storage classes after the write lands on disk, never before:
//  a handler that reads back a stale file would render the state the user just
//  changed away from. Handlers must only read and rebuild. Writing from one
//  turns the next save into another notification and the pair never settles.
//

import Foundation

extension Notification.Name {
    static let connectionsDidChange = Notification.Name("com.SchemaStudio.connectionsDidChange")
}
