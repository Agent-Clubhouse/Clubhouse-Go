#if canImport(MetricKit) && os(iOS)
import Foundation
import MetricKit

/// Optional: forwards MetricKit crash, hang and resource-exception diagnostics as classified
/// `app.error` logs. Only numbers and closed classes are sent: no call stacks, binary paths,
/// termination strings or memory-region text. iOS delivers payloads for a previous run, usually
/// on the next launch; payloads that arrive while not enrolled are discarded, never stored.
public final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let telemetry: Telemetry
    public init(telemetry: Telemetry) { self.telemetry = telemetry }
    public func start() { MXMetricManager.shared.add(self) }
    public func stop() { MXMetricManager.shared.remove(self) }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var attrs = base(crash.metaData, "crash")
                if let v = crash.exceptionType?.intValue { attrs["app.crash.mach_exception_type"] = .int(v) }
                if let v = crash.exceptionCode?.intValue { attrs["app.crash.mach_exception_code"] = .int(v) }
                if let v = crash.signal?.intValue { attrs["app.crash.signal"] = .int(v) }
                telemetry.log(.fatal, "app.error", attrs)
            }
            for hang in payload.hangDiagnostics ?? [] {
                var attrs = base(hang.metaData, "hang")
                attrs["app.hang.duration_ms"] = .int(Int(hang.hangDuration.converted(to: .milliseconds).value))
                telemetry.log(.error, "app.error", attrs)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                var attrs = base(cpu.metaData, "cpu_exception")
                attrs["app.cpu.time_ms"] = .int(Int(cpu.totalCPUTime.converted(to: .milliseconds).value))
                telemetry.log(.warn, "app.error", attrs)
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                var attrs = base(disk.metaData, "disk_write_exception")
                attrs["app.disk.writes_bytes"] = .int(Int(disk.totalWritesCaused.converted(to: .bytes).value))
                telemetry.log(.warn, "app.error", attrs)
            }
        }
    }
    private func base(_ meta: MXMetaData, _ errorClass: String) -> TelemetryAttributes {
        ["app.error.class": .string(errorClass), "app.error.source": "metrickit",
         "app.build": .string(String(meta.applicationBuildVersion.prefix(32))),
         "os.version": .string(String(meta.osVersion.prefix(64)))]
    }
}
#endif
