import ActivityKit
import Foundation

struct QueryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var endedAt: Date?
        var rowsStreamed: Int
    }

    let connectionId: UUID
    let connectionName: String
    let queryPreview: String
}
