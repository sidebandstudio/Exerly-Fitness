import Darwin
import Foundation
import os

/// Cold launch to logging (PARITY B03). Two figures, both ending once the
/// frame that lays out Today's logging controls (Log again, or the shortcuts
/// when there's no Log again) where they stay has been committed: layout
/// gives them their place on screen, and this ends once the run loop has
/// handed that frame to the render server, which shows it at the next
/// refresh (`NextFrame`). The places are reported too, so the UI tests can
/// check them against the accessibility tree as the launch returns:
/// - from the process starting, read from the kernel, so it includes loading
///   the app's code: the end-to-end number LaunchToLoggingUITests gates on;
/// - from the app's own start, also as a signpost interval for Instruments,
///   which closes when the controls have settled, a quarter second after.
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
    private static var committing = false
    /// Food entries on the device when launch ended, reported with its time.
    private static var entries = 0
    /// Where each logging control was laid out, in window points, as of the
    /// committed frame: `logAgain` and `shortcuts`.
    private static var frames: [String: CGRect] = [:]
    /// When the frame that last moved a logging control was committed.
    private static var placedAt: Date?

    static func begin() {
        guard interval == nil, started == nil else { return }
        started = Date()
        interval = signposter.beginInterval(name)
        mark("app init")
    }

    /// A logging control has been laid out at `frame`: ends at the commit of
    /// the frame that put the logging controls where they stay. A launch whose
    /// first frame came before the bars above Today had settled drew them all
    /// 126 pt higher, then moved them (3 in 200 launches, 2026-10-23), so the
    /// end waits until none has moved for `settling`. A change of size where
    /// it stands, as Log again's chips after a sync, doesn't move it.
    static func loggingLaidOut(_ control: String, at frame: CGRect, entries: Int) {
        guard interval != nil, !frame.isEmpty else { return }
        let moved = frames[control].map { $0.origin != frame.origin } ?? true
        frames[control] = frame
        Self.entries = entries
        guard moved, !committing else { return }
        committing = true
        mark("\(control) laid out")
        NextFrame { committed() }
    }

    /// How long the logging controls must stay put after a frame places them.
    private static let settling: Duration = .milliseconds(250)

    /// The frame placing them is with the render server: launch ends there
    /// unless a later frame moves them first.
    private static func committed() {
        committing = false
        let at = Date()
        placedAt = at
        Task { @MainActor in
            try? await Task.sleep(for: settling)
            if placedAt == at { finish(at: at) }
        }
    }

    private static func finish(at now: Date) {
        guard let interval, let started else { return }
        signposter.endInterval(name, interval)
        Self.interval = nil
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
        let places = frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["processToReadyMs": processMs, "initToReadyMs": appMs,
                                                                        "entries": entries, "frames": places])
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

/// Calls back once, after the frame being built now has been committed to the
/// render server, which shows it at the next refresh: when the main run loop
/// next goes to sleep, after Core Animation's own commit there. The loop is
/// woken for that, since an idle one doesn't come round again on its own: a
/// display link, and this without the wake, went unfired for over 30 s while
/// three years of history opened (2026-10-21). The run loop holds it until
/// then, so it needn't be kept.
@MainActor
final class NextFrame {
    @discardableResult
    init(_ done: @escaping @MainActor () -> Void) {
        // Core Animation commits at 2,000,000; the latest order runs after it.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) { _, _ in
            MainActor.assumeIsolated { done() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
