// Private #611 attribution instrumentation. Never part of the recovery PR.
import Foundation
#if os(macOS)
import Darwin
#endif

enum PackageStallTrace {
    #if os(macOS)
    private static let descriptor: Int32 = {
        guard let path = ProcessInfo.processInfo.environment["GO_PACKAGE_STALL_TRACE"] else { return -1 }
        return open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    }()
    #endif

    static func record(_ stage: String, id: String, detail: String = "") {
        #if os(macOS)
        guard descriptor >= 0 else { return }
        let fields: [String: Any] = ["pid": Int(getpid()), "uptime": ProcessInfo.processInfo.systemUptime,
                                    "stage": stage, "id": id, "detail": detail]
        guard var bytes = try? JSONSerialization.data(withJSONObject: fields) else { return }
        bytes.append(10)
        bytes.withUnsafeBytes { buffer in
            _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        #endif
    }
}
