import Darwin
import Foundation
import QuartzCore
import os

/// Cold launch to logging (PARITY B03). Two figures, both ending once the
/// frame that draws Today's logging controls (Log again, or the shortcuts when
/// there's no Log again) has been presented: their `onAppear` runs while that
/// frame is built, the next display refresh commits it, and the one after
/// follows its presentation, which is when this ends:
/// - from the process starting, read from the kernel, so it includes loading
///   the app's code: the end-to-end number LaunchToLoggingUITests gates on;
/// - a signpost interval from the app's own start, for Instruments and
///   XCTOSSignpostMetric, as a diagnostic.
/// Only the first Today of a launch ends them. Both are logged, to read on a
/// phone in Console; a Debug build run by the UI tests also reports them to
/// its fixture API.
@MainActor
enum LaunchTiming {
    static let subsystem = "com.exerly.fitness"
    static let category = "launch"
    static let name: StaticString = "LaunchToLogging"
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static let log = Logger(subsystem: subsystem, category: category)
    private static var interval: OSSignpostIntervalState?
    private static var started: Date?
    private static var frame: NextFrame?
    /// Food entries on the device when launch ended, reported with its time.
    private static var entries = 0

    static func begin() {
        guard interval == nil, started == nil else { return }
        started = Date()
        interval = signposter.beginInterval(name)
        mark("app init")
    }

    /// Today's logging controls have appeared: ends once the frame that
    /// draws them has been presented, two display refreshes on.
    static func loggingReady(entries: Int) {
        guard interval != nil, frame == nil else { return }
        Self.entries = entries
        frame = NextFrame { frame = NextFrame { finish() } }
    }

    private static func finish() {
        guard let interval, let started else { return }
        signposter.endInterval(name, interval)
        Self.interval = nil
        frame = nil
        let now = Date()
        let process = now.timeIntervalSince(processStart) * 1000, app = now.timeIntervalSince(started) * 1000
        log.info("launch: logging on screen \(Int(process)) ms after the process started, \(Int(app)) ms after the app's, \(entries) entries")
        report(processMs: process, appMs: app)
    }

    private static func mark(_ step: String) {
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        log.info("launch: \(step, privacy: .public) at \(ms) ms after the process started")
    }

    /// Only a Debug build the UI tests launched against a local fixture API.
    private static func report(processMs: Double, appMs: Double) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["EXERLY_TEST_STORE_ID"] != nil, let base = environment["EXERLY_API_BASE_URL"],
              let url = URL(string: base + "/__test/launch-timings"), url.host == "127.0.0.1",
              let port = url.port, (39000...39299).contains(port) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["processToReadyMs": processMs, "initToReadyMs": appMs,
                                                                        "entries": entries])
        URLSession.shared.dataTask(with: request).resume()
        #endif
    }

    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
}

/// Calls back once, on the next display refresh: after the frame being built
/// now has been drawn. Its display link holds it until then, so it needn't be kept.
@MainActor
final class NextFrame: NSObject {
    private let done: () -> Void
    private var link: CADisplayLink?

    init(_ done: @escaping () -> Void) {
        self.done = done
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        done()
    }
}
