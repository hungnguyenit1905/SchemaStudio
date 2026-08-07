import Foundation

extension Sequence<UInt8> {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
