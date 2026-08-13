//
//  DiagnosticTagValueSanitizerTests.swift
//  TableProDiagnosticsTests
//

import Foundation
import Testing

@testable import TableProDiagnostics

@Suite("DiagnosticTagValueSanitizer")
struct DiagnosticTagValueSanitizerTests {
    private static let unsafeValues = [
        "connection to server at \"10.0.0.4\", port 5432 failed",
        "FATAL: password authentication failed for user \"admin\"",
        "SELECT * FROM customers",
        "postgres://admin@db.internal:5432/sales",
        "/Users/hung/Documents/sales.sqlite",
        "db.internal",
        "prod-db.company.com",
        "192.168.1.40",
        "admin@example.com",
        "sales database",
        ""
    ]

    @Test("Accepts the value each key actually carries")
    func acceptsSafeValues() {
        let accepted: [(DiagnosticTagKey, String)] = [
            (.databaseType, "postgresql"),
            (.databaseType, "cloudflare_d1"),
            (.errorCase, "connectionFailed"),
            (.transferPhase, "copyRows"),
            (.driverErrorCode, "28P01"),
            (.driverErrorCode, "ORA-01017"),
            (.pluginId, "com.TablePro.MySQLDriver"),
            (.pluginKitVersion, "12"),
            (.attemptCount, "6")
        ]
        for (key, value) in accepted {
            #expect(DiagnosticTagValueSanitizer.sanitize(value, for: key) == value)
        }
    }

    @Test("No key accepts a value that could carry user data")
    func rejectsUnsafeValuesForEveryKey() {
        for value in Self.unsafeValues {
            for key in DiagnosticTagKey.allCases {
                #expect(
                    DiagnosticTagValueSanitizer.sanitize(value, for: key) == DiagnosticTagValueSanitizer.placeholder,
                    "\(key.rawValue) accepted \(value)"
                )
            }
        }
    }

    @Test("A hostname cannot pass as a plugin bundle ID")
    func rejectsHostnameShapedPluginId() {
        #expect(DiagnosticTagValueSanitizer.isValid("com.TablePro.MySQLDriver", for: .pluginId))
        #expect(!DiagnosticTagValueSanitizer.isValid("db.internal", for: .pluginId))
        #expect(!DiagnosticTagValueSanitizer.isValid("com.TablePro.", for: .pluginId))
        #expect(!DiagnosticTagValueSanitizer.isValid("org.TablePro.MySQLDriver", for: .pluginId))
    }

    @Test("A key accepts only its own shape")
    func shapesDoNotOverlap() {
        #expect(!DiagnosticTagValueSanitizer.isValid("ORA-01017", for: .errorCase))
        #expect(!DiagnosticTagValueSanitizer.isValid("com.TablePro.MySQLDriver", for: .databaseType))
        #expect(!DiagnosticTagValueSanitizer.isValid("twelve", for: .pluginKitVersion))
        #expect(!DiagnosticTagValueSanitizer.isValid("1.2.0", for: .attemptCount))
    }

    @Test("Rejects a value longer than the limit even when every character is allowed")
    func rejectsOverlongValue() {
        let overlong = String(repeating: "a", count: DiagnosticTagValueSanitizer.maxLength + 1)
        #expect(!DiagnosticTagValueSanitizer.isValid(overlong, for: .errorCase))

        let atLimit = String(repeating: "a", count: DiagnosticTagValueSanitizer.maxLength)
        #expect(DiagnosticTagValueSanitizer.sanitize(atLimit, for: .errorCase) == atLimit)
    }

    @Test("Rejects non-ASCII, which a localized driver message would carry")
    func rejectsNonAscii() {
        for key in DiagnosticTagKey.allCases {
            #expect(!DiagnosticTagValueSanitizer.isValid("mật_khẩu", for: key))
            #expect(!DiagnosticTagValueSanitizer.isValid("données", for: key))
            #expect(!DiagnosticTagValueSanitizer.isValid("表名", for: key))
        }
    }
}
