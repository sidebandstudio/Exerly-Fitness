#if DEBUG
import Combine
import CoreGraphics
import ExerlyCore
import Foundation

/// The simulator has no camera. Under UI tests with EXERLY_TEST_BARCODE_FEED
/// set, the scanner watches the fixture API for a synthetic code, draws it,
/// and reads it through the camera's decoder and two-read check: frames as
/// the camera would deliver them, a thirtieth of a second apart.
final class BarcodeTestFeed: ObservableObject, BarcodeSource {
    @Published private(set) var image: CGImage?
    /// Watching the fixture: a code posted from now on is read.
    @Published private(set) var primed = false
    /// When the scanner started watching, became ready, and last saw a code.
    private(set) var started = Date(), primedAt: Date?, receivedAt: Date?
    let accepted = PassthroughSubject<ScannedCode, Never>()
    private let base: URL?
    private let decoder = BarcodeDecoder()
    private var consensus = BarcodeConsensus()
    private var seen: Int?
    private var polling: Task<Void, Never>?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            && ProcessInfo.processInfo.environment["EXERLY_TEST_BARCODE_FEED"] == "1"
    }

    init() {
        base = Self.isEnabled ? ProcessInfo.processInfo.environment["EXERLY_API_BASE_URL"].flatMap(URL.init(string:)) : nil
    }

    var isActive: Bool { base != nil }

    func start() {
        guard polling == nil, base != nil else { return }
        if !primed { started = Date() }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    private struct Feed: Decodable {
        var id: Int
        var payload: String?
    }

    @MainActor private func poll() async {
        guard let base, let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("__test/barcode-feed")),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return }
        // A code already up when the scanner opened belongs to an earlier scan.
        guard let seen else { self.seen = feed.id; primedAt = Date(); primed = true; return }
        guard feed.id != seen else { return }
        self.seen = feed.id
        guard let payload = feed.payload, let image = SyntheticBarcode.image(for: payload) else { return }
        receivedAt = Date()
        self.image = image
        consensus.reset()
        let start = Date()
        for frame in 0..<4 {
            let codes = decoder.decode(image).codes
            for code in consensus.observe(codes, at: start.addingTimeInterval(Double(frame) / 30)) { accepted.send(code) }
        }
    }
}
#endif
