import Foundation

/// A per-row writer into a bulk load path (`COPY FROM STDIN`,
/// `LOAD DATA LOCAL INFILE`). The writer owns the protocol stream and decides
/// when to flush; callers feed it one converted row at a time and never build
/// the whole batch in memory themselves.
public protocol PluginBulkLoadWriter: Sendable {
    func write(row: [PluginCellValue]) async throws

    /// Ends the stream and reports how many rows the server accepted.
    func finish() async throws -> Int

    /// Tears the stream down after a failure so the connection never stays in
    /// a half-open bulk state. Must be safe to call after `finish`.
    func abort() async
}

/// Server-side ceilings the app reads instead of guessing, so a batch is cut
/// by what the target actually allows.
public struct PluginServerLimits: Sendable {
    public let maxPacketBytes: Int?
    public let maxBindParameters: Int?
    public let supportsLocalInfile: Bool?

    public init(
        maxPacketBytes: Int? = nil,
        maxBindParameters: Int? = nil,
        supportsLocalInfile: Bool? = nil
    ) {
        self.maxPacketBytes = maxPacketBytes
        self.maxBindParameters = maxBindParameters
        self.supportsLocalInfile = supportsLocalInfile
    }
}

/// Whether a target can turn its constraint checks off for a bulk load.
public enum PluginConstraintDisableCapability: String, Sendable {
    case supported
    case notPermitted
    case notApplicable
    case unknown
}
