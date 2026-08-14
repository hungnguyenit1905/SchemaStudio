//
//  MariaDBPluginConnection+LocalInfile.swift
//  MySQLDriverPlugin
//

import CMariaDB
import Foundation

/// `LOAD DATA LOCAL INFILE` support. The client half of that statement is a
/// callback the library invokes while the query is in flight; this file installs
/// a handler that serves the transfer's own bytes and never touches the file
/// system, then restores the library default when the load ends.
extension MariaDBPluginConnection {
    /// Runs the load on the connection queue and returns the rows the server
    /// accepted. The call blocks for the whole load, which is why the stream
    /// has to be fed from another task.
    func loadDataLocalInfile(
        statement: String,
        stream: MySQLLocalInfileStream
    ) async throws -> UInt64 {
        let sql = String(statement)
        return try await withConnectionHandle { [self] mysql in
            var enableLocalInfile: UInt32 = 1
            mysql_options(mysql, MYSQL_OPT_LOCAL_INFILE, &enableLocalInfile)

            let context = Unmanaged.passRetained(MySQLLocalInfileContext(stream: stream))
            defer {
                mysql_set_local_infile_default(mysql)
                context.release()
            }

            mysql_set_local_infile_handler(
                mysql,
                localInfileInit,
                localInfileRead,
                localInfileEnd,
                localInfileError,
                context.toOpaque()
            )

            let status = sql.withCString { pointer in
                mysql_real_query(mysql, pointer, UInt(sql.utf8.count))
            }
            guard status == 0 else { throw self.lastError() }
            return mysql_affected_rows(mysql)
        }
    }
}

/// Carries the stream across the C boundary. The handler is handed the pointer
/// libmariadb stores as user data, so the class has to outlive the query and is
/// retained for exactly that long.
final class MySQLLocalInfileContext {
    let stream: MySQLLocalInfileStream

    init(stream: MySQLLocalInfileStream) {
        self.stream = stream
    }
}

/// The server sends a file name and the client is free to ignore it. Ignoring
/// it is the point: a server that asks for `/etc/passwd` gets the transfer's
/// rows like every other request, because no path is ever opened.
private let localInfileInit: @convention(c) (
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Int32 = { handle, _, userData in
    guard let handle, let userData else { return 1 }
    handle.pointee = userData
    return 0
}

private let localInfileRead: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<CChar>?,
    UInt32
) -> Int32 = { handle, buffer, size in
    guard let handle, let buffer else { return -1 }
    let context = Unmanaged<MySQLLocalInfileContext>.fromOpaque(handle).takeUnretainedValue()
    let read = context.stream.read(into: buffer, capacity: Int(size))
    return Int32(read)
}

private let localInfileEnd: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in }

private let localInfileError: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<CChar>?,
    UInt32
) -> Int32 = { handle, message, size in
    guard let handle, let message, size > 0 else { return 0 }
    let context = Unmanaged<MySQLLocalInfileContext>.fromOpaque(handle).takeUnretainedValue()
    let reason = context.stream.abortReason ?? "Transfer aborted"
    let bytes = Array(reason.utf8.prefix(Int(size) - 1))
    bytes.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else { return }
        message.withMemoryRebound(to: UInt8.self, capacity: bytes.count) { target in
            target.update(from: base, count: bytes.count)
        }
    }
    message[bytes.count] = 0
    return 0
}
