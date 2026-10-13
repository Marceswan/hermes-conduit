import Foundation
import Darwin

/// Marks files Conduit writes from gateway-controlled bytes as downloaded, so
/// Gatekeeper checks them when the user opens them from Finder. `Data.write`
/// adds no quarantine attribute on its own.
enum FileQuarantine {
    struct Failure: Error { let errno: Int32 }

    static func markQuarantined(_ url: URL) throws {
        // flags;hex unix time;agent name;  (0081 = downloaded, user not yet prompted)
        let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Conduit;"
        let bytes = Array(value.utf8)
        let status = setxattr(url.path, "com.apple.quarantine", bytes, bytes.count, 0, 0)
        guard status == 0 else { throw Failure(errno: errno) }
    }
}
