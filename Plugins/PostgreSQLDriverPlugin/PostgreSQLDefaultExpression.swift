import Foundation

enum PostgreSQLDefaultExpression {
    static func isFunctionCall(_ value: String) -> Bool {
        guard value.hasSuffix(")"),
              !value.contains(";"),
              !value.contains("--"),
              !value.contains("/*") else { return false }
        let functionPrefix = #"^(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*)(?:\.(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*))*\("#
        return value.range(of: functionPrefix, options: .regularExpression) != nil
    }
}
