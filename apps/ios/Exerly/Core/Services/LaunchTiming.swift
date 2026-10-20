import Darwin
import Foundation
import os

/// Cold launch to logging (PARITY B03): a signpost interval from the app's
/// start to Today's first screen with its logging controls, which
/// LaunchToLoggingUITests measures with XCTOSSignpostMetric. Only the first
/// Today of a launch ends it. Both ends are also logged with the time since
/// the process started, to read on a phone in Console.
@MainActor
enum LaunchTiming {
    static let subsystem = "com.exerly.fitness"
    static let category = "launch"
    static let name: StaticString = "LaunchToLogging"
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static let log = Logger(subsystem: subsystem, category: category)
    private static var interval: OSSignpostIntervalState?

    static func begin() {
        guard interval == nil else { return }
        interval = signposter.beginInterval(name)
        mark("app init")
    }

    /// Today is on screen with its logging controls.
    static func loggingReady() {
        guard let interval else { return }
        signposter.endInterval(name, interval)
        Self.interval = nil
        mark("logging ready")
    }

    private static func mark(_ step: String) {
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        log.info("launch: \(step, privacy: .public) at \(ms) ms after the process started")
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
