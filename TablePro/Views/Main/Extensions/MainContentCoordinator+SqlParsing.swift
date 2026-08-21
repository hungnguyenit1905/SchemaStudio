//
//  MainContentCoordinator+SqlParsing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func extractTableName(from sql: String) -> String? {
        QuerySqlParser.extractTableName(from: sql)
    }
}
