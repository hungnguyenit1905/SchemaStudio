//
//  TransferBindParameterLimits.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The bind-parameter ceiling a prepared batch has to stay under, shared by Data
/// Transfer and the generation engine so a fix to one vendor's number never
/// drifts out of step with the other caller.
///
/// The server's own reported limit always wins where there is one. The
/// per-vendor fallback below is what a batch is cut to when `serverLimits()`
/// returns nil, which every driver that does not implement it does.
enum TransferBindParameterLimits {
    static func maxBindParameters(for databaseType: DatabaseType, limits: PluginServerLimits?) -> Int {
        if let maxBind = limits?.maxBindParameters { return maxBind }
        switch databaseType {
        case .sqlite: return 32_766
        case .mssql: return 2_100
        default: return 65_535
        }
    }
}
