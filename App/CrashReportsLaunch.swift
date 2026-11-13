import Foundation
import HerdrKit
import MetricKit

/// The app side of the opt-in crash reports (`CrashReport` / `CrashReporter` in HerdrKit):
/// `AppDelegate` calls `start()` at launch, which subscribes to MetricKit and sends whatever
/// an earlier launch queued. MetricKit delivers a crash or hang diagnostic on the launch after
/// it happened. Each one becomes a report only while Settings › About › "Share anonymous usage
/// count" is on; switching that off deletes the queue (`usageCountSwitched(on:)`).
///
/// Release builds send to the guest relay. DEBUG builds never do: every UI test, mock mode and
/// developer phone runs one. A DEBUG launch sends only when `HERDR_CRASH_REPORT_URL` names a
/// stub endpoint, and then also feeds the recorded `MXDiagnosticPayload` JSON at the path in
/// `HERDR_MOCK_METRICKIT_PAYLOAD`, if any, through the same reporter, since MetricKit
/// delivers nothing in the simulator (Tools/ci/crash-reports.sh).
enum CrashReportsLaunch {
    /// Reports waiting to be sent: Caches, so never backed up.
    static let queueDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CrashReports", isDirectory: true)

    private static let reporter: CrashReporter? = {
        #if DEBUG
        guard let stub = ProcessInfo.processInfo.environment["HERDR_CRASH_REPORT_URL"],
              let endpoint = URL(string: stub)
        else { return nil }
        return CrashReporter(directory: queueDirectory, endpoint: endpoint)
        #else
        return CrashReporter(directory: queueDirectory)
        #endif
    }()

    private static let subscriber = Subscriber()

    static func start() {
        guard let reporter else { return }
        MXMetricManager.shared.add(subscriber)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["HERDR_MOCK_METRICKIT_PAYLOAD"],
           let json = FileManager.default.contents(atPath: path) {
            let diagnostics = CrashReport.diagnostics(fromPayload: json)
            Task { await reporter.receive(diagnostics) }
            return
        }
        #endif
        Task { await reporter.flush() }
    }

    /// The usage-count switch changed. Off deletes every queued report at once.
    static func usageCountSwitched(on: Bool) {
        guard !on else { return }
        try? FileManager.default.removeItem(at: queueDirectory)
    }

    /// What a report may carry from MetricKit's diagnostics, read field by field: the crash and
    /// hang diagnostics only, and of their metadata only the version, build, OS and device.
    static func diagnostics(from payload: MXDiagnosticPayload) -> [CrashReport.Diagnostic] {
        let crashes = (payload.crashDiagnostics ?? []).map { crash in
            CrashReport.Diagnostic(kind: .crash,
                                   version: crash.applicationVersion,
                                   build: crash.metaData.applicationBuildVersion,
                                   os: crash.metaData.osVersion,
                                   device: crash.metaData.deviceType,
                                   exceptionType: crash.exceptionType?.intValue,
                                   exceptionCode: crash.exceptionCode?.intValue,
                                   signal: crash.signal?.intValue,
                                   terminationReason: crash.terminationReason,
                                   callStackTree: crash.callStackTree.jsonRepresentation())
        }
        let hangs = (payload.hangDiagnostics ?? []).map { hang in
            CrashReport.Diagnostic(kind: .hang,
                                   version: hang.applicationVersion,
                                   build: hang.metaData.applicationBuildVersion,
                                   os: hang.metaData.osVersion,
                                   device: hang.metaData.deviceType,
                                   hangSeconds: hang.hangDuration.converted(to: .seconds).value,
                                   callStackTree: hang.callStackTree.jsonRepresentation())
        }
        return crashes + hangs
    }

    private final class Subscriber: NSObject, MXMetricManagerSubscriber {
        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            guard let reporter = CrashReportsLaunch.reporter else { return }
            let diagnostics = payloads.flatMap(CrashReportsLaunch.diagnostics(from:))
            Task { await reporter.receive(diagnostics) }
        }
    }
}
