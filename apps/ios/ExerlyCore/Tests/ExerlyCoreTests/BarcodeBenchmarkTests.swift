import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import XCTest
@testable import ExerlyCore

/// The scanner benchmark. Synthetic codes for every retail symbology are
/// drawn on a pack, put through what goes wrong in a kitchen (rotation, a
/// tilted or curved pack, focus, glare, dark, distance, damage), and read as
/// the camera reads them: `BarcodeDecoder` on two jittered frames, then the
/// two-read `BarcodeConsensus`. It reports the hit rate for each symbology
/// and condition, and fails on any wrong read. Results: docs/BARCODE.md.
///
/// It runs here, on the Mac, because the iOS simulator can't run Vision's
/// current barcode revision (no inference context); the Mac runs the same
/// `BarcodeDecoder` at the same revision a phone does.
final class BarcodeBenchmarkTests: XCTestCase {
    enum Condition: String, CaseIterable {
        case clean, rotated, perspective, curved, blurred, lowContrast = "low contrast", lowLight = "low light", small, damaged
    }

    /// Vision misses some GS1 DataBar codes even printed perfectly, at any bar
    /// height; their widths match the bwip-js reference, which Vision misses
    /// too. Every other symbology reads every clean code.
    static let cleanFloor = ["GS1 DataBar": 0.7, "GS1 DataBar Stacked": 0.6]

    struct Sample {
        let symbology: String
        let expected: GTIN
        /// The printed label: dark modules on white, at about 4 px a module.
        let label: CIImage
    }

    private let frame = CGSize(width: 960, height: 720)
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func testEverySymbologyUnderEveryConditionAndNoWrongReads() throws {
        var random = SplitMix(seed: 20_261_020)
        // EXERLY_BENCH_ONLY=EAN-8,UPC-E limits a run to some symbologies while tuning.
        let only = ProcessInfo.processInfo.environment["EXERLY_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let samples = try (encodedSamples(&random) + fixtureSamples()).filter { only?.contains($0.symbology) ?? true }
        let decoder = BarcodeDecoder()
        _ = decoder.decode(scene(samples[0].label, .clean, random: &random))
        if decoder.revision == 1 {
            throw XCTSkip("Vision's current barcode revision needs a neural engine or GPU this machine lacks; revision 1 isn't what a phone runs")
        }
        var hits: [String: [Condition: Int]] = [:], totals: [String: Int] = [:]
        var wrong: [String] = [], rawWrong = 0, tooSmall = 0, decodeTime: TimeInterval = 0, decodes = 0
        for sample in samples {
            totals[sample.symbology, default: 0] += 1
            for condition in Condition.allCases {
                var consensus = BarcodeConsensus()
                var accepted: [ScannedCode] = []
                var seen: [String] = [], misread = false
                for index in 0..<2 {
                    let image = scene(sample.label, condition, random: &random)
                    let start = Date()
                    let read = decoder.decode(image)
                    decodeTime += Date().timeIntervalSince(start)
                    decodes += 1
                    rawWrong += read.codes.filter { $0.gtin != sample.expected }.count
                    tooSmall += read.tooSmall
                    misread = misread || read.codes.contains { $0.gtin != sample.expected }
                    seen.append("frame \(index): " + read.observations.joined(separator: "; "))
                    accepted += consensus.observe(read.codes, at: Date(timeIntervalSinceReferenceDate: Double(index) / 30))
                }
                if accepted.contains(where: { $0.gtin == sample.expected }) { hits[sample.symbology, default: [:]][condition, default: 0] += 1 }
                wrong += accepted.filter { $0.gtin != sample.expected }.map { "\(sample.symbology) \(condition.rawValue): \($0.gtin) for \(sample.expected)" }
                if ProcessInfo.processInfo.environment["EXERLY_BENCH_SHAPES"] == "1" {
                    print("SHAPE|\(sample.symbology) \(condition.rawValue): " + seen.joined(separator: " | "))
                }
                if misread {
                    print("MISREAD|\(sample.symbology) \(condition.rawValue) \(sample.expected): " + seen.joined(separator: " | "))
                }
            }
        }
        let report = table(hits: hits, totals: totals, order: samples.map(\.symbology))
            + "\nWrong reads accepted: \(wrong.count). Single frames with a wrong but check-digit-valid read: \(rawWrong)."
            + " Short-code reads refused as too small to trust: \(tooSmall)."
            + "\nMean decode \(Int(decodeTime / Double(max(decodes, 1)) * 1000)) ms over \(decodes) frames of \(Int(frame.width))×\(Int(frame.height)) on this machine.\n"
        print(report.split(separator: "\n").map { "BENCH|\($0)" }.joined(separator: "\n"))
        let attachment = XCTAttachment(string: report)
        attachment.name = "barcode-benchmark.md"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("barcode-benchmark.md"), atomically: true, encoding: .utf8)

        XCTAssertEqual(wrong, [], "A wrong read must never be accepted")
        for (symbology, total) in totals where only == nil {
            let floor = Self.cleanFloor[symbology] ?? 1
            XCTAssertGreaterThanOrEqual(Double(hits[symbology]?[.clean] ?? 0), floor * Double(total), "Clean \(symbology) reads")
        }
    }

    // MARK: Samples

    private func encodedSamples(_ random: inout SplitMix) throws -> [Sample] {
        var samples: [Sample] = []
        func digits(_ count: Int) -> String { String((0..<count).map { _ in Character(String(random.next() % 10)) }) }
        func checked(_ body: String) -> String { body + String(GTIN.checkDigit(of: body)!) }
        func add(_ symbology: String, _ expected: String, _ bars: BarcodeBars?) throws {
            let bars = try XCTUnwrap(bars, "\(symbology) \(expected)")
            samples.append(Sample(symbology: symbology, expected: try XCTUnwrap(GTIN(expected)), label: CIImage(cgImage: SyntheticBarcode.image(bars))))
        }
        for _ in 0..<10 {
            let ean = checked(String(1 + random.next() % 9) + digits(11))
            try add("EAN-13", ean, BarcodeEncoder.ean13(ean))
            let upcA = checked("0" + digits(10))
            try add("UPC-A", upcA, BarcodeEncoder.upcA(upcA))
            let ean8 = checked(digits(7))
            try add("EAN-8", ean8, BarcodeEncoder.ean8(ean8))
            let expanded = try XCTUnwrap(GTIN.expandUPCE("0" + digits(5) + String(5 + random.next() % 5)))
            let upcE = try XCTUnwrap(GTIN.compressUPCA(expanded))
            try add("UPC-E", expanded, BarcodeEncoder.upcE(upcE))
            let itf = checked(String(1 + random.next() % 8) + digits(12))
            try add("ITF-14", itf, BarcodeEncoder.itf14(itf))
            let gtin14 = checked("0" + digits(12))
            let fields: [(ai: String, value: String)] = random.next() % 2 == 0 ? [("01", gtin14)] : [("01", gtin14), ("3103", "000512")]
            try add("GS1-128", gtin14, BarcodeEncoder.gs1128(fields))
            let dataBar = checked("0" + digits(12))
            try add("GS1 DataBar", dataBar, BarcodeEncoder.dataBar(dataBar))
            let stacked = checked("0" + digits(12))
            try add("GS1 DataBar Stacked", stacked, BarcodeEncoder.dataBarStacked(stacked))
            let link = checked("0" + digits(12))
            let qr = try XCTUnwrap(SyntheticBarcode.qr("https://id.gs1.org/01/\(link)", module: 6))
            samples.append(Sample(symbology: "GS1 Digital Link QR", expected: try XCTUnwrap(GTIN(link)), label: CIImage(cgImage: qr)))
        }
        return samples
    }

    /// Symbologies with no encoder here, drawn once by bwip-js (MIT) for
    /// synthetic GTINs under GS1's demonstration prefix 950: see
    /// BarcodeFixtures and docs/BARCODE.md.
    private func fixtureSamples() throws -> [Sample] {
        let names = ["databarlimited": "GS1 DataBar Limited", "databarexpanded": "GS1 DataBar Expanded",
                     "datamatrix": "GS1 DataMatrix", "microqr": "Micro QR"]
        let urls = Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: "BarcodeFixtures") ?? []
        var samples: [Sample] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 2, let name = names[String(parts[0])], let expected = GTIN(parts[1]),
                  let image = CIImage(contentsOf: url) else { continue }
            // Transparent background onto white, grey, with a quiet zone.
            let white = CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -24, dy: -24))
            let label = image.composited(over: white).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            samples.append(Sample(symbology: name, expected: expected, label: label.transformed(by: .init(translationX: 24, y: 24))))
        }
        XCTAssertEqual(samples.count, 24, "Six fixtures for each of four symbologies")
        return samples
    }

    // MARK: Scenes

    /// A camera frame: the label under a condition on a pack, slightly
    /// jittered so two frames differ as a hand-held phone's do. A label is
    /// framed to at most 85% of the frame's width, as a person fills the
    /// viewfinder's window; labels are drawn at about 4 px a module.
    private func scene(_ label: CIImage, _ condition: Condition, random: inout SplitMix) -> CGImage {
        let jitter = random.unit() * 4 - 2
        let framed = min(1, frame.width * 0.85 / label.extent.width)
        var image = label.transformed(by: CGAffineTransform(translationX: -label.extent.midX, y: -label.extent.midY)
            .concatenating(CGAffineTransform(scaleX: framed, y: framed)))
        switch condition {
        case .clean, .lowContrast, .lowLight, .blurred: break
        case .rotated: image = image.transformed(by: CGAffineTransform(rotationAngle: (random.next() % 2 == 0 ? 1 : -1) * 35 * .pi / 180))
        case .perspective: image = tilted(image)
        case .curved: image = curved(image)
        case .small: image = image.transformed(by: CGAffineTransform(scaleX: 0.4, y: 0.4))
        case .damaged: image = damaged(image, random: &random)
        }
        image = image.transformed(by: CGAffineTransform(rotationAngle: jitter * .pi / 180))
        image = image.transformed(by: CGAffineTransform(translationX: frame.width / 2 + jitter * 3, y: frame.height / 2))
        let bounds = CGRect(origin: .zero, size: frame)
        let pack = CIImage(color: CIColor(red: 0.62, green: 0.62, blue: 0.62)).cropped(to: bounds)
        var scene = image.composited(over: pack).cropped(to: bounds)
        switch condition {
        // Half a module of defocus.
        case .blurred: scene = scene.applyingGaussianBlur(sigma: 2 * framed).cropped(to: bounds)
        case .lowContrast: scene = levels(scene, black: 0.45, white: 0.72)
        case .lowLight: scene = levels(scene, black: 0.03, white: 0.2)
        default: break
        }
        let gray = Gray(context.createCGImage(scene, from: bounds, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!)
        // Gaussian sensor noise: σ 1% of full scale in light, 3.5% in the dark.
        gray.addNoise(scale: condition == .lowLight ? 3.5 : 1, start: random.next())
        return gray.image
    }

    private func levels(_ image: CIImage, black: CGFloat, white: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: white - black, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: white - black, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: white - black, w: 0), "inputBiasVector": CIVector(x: black, y: black, z: black, w: 0),
        ])
    }

    /// The pack turned about 40° away: its far side shorter and narrower.
    private func tilted(_ image: CIImage) -> CIImage {
        let box = image.extent
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = CGPoint(x: box.minX, y: box.maxY)
        filter.bottomLeft = CGPoint(x: box.minX, y: box.minY)
        filter.topRight = CGPoint(x: box.maxX - box.width * 0.24, y: box.maxY - box.height * 0.2)
        filter.bottomRight = CGPoint(x: box.maxX - box.width * 0.24, y: box.minY + box.height * 0.2)
        return filter.outputImage!
    }

    /// Wrapped round a can five times the label's width, as a 37 mm EAN-13
    /// on a 60 mm can, seen from a little above: bars bunch toward the edges,
    /// which darken and bow.
    private func curved(_ image: CIImage) -> CIImage {
        let source = Gray(context.createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!)
        let radius = 5 * Double(source.width) / (2 * .pi)
        let half = Double(source.width) / 2
        let outWidth = Int(2 * radius * sin(half / radius)), bow = 0.12 * radius
        let output = Gray(width: outWidth, height: source.height + Int(bow) + 2, fill: 158)
        for x in 0..<outWidth {
            let offset = Double(x) - Double(outWidth) / 2
            let angle = asin(max(-1, min(1, offset / radius)))
            let u = Int(radius * angle + half)
            guard u >= 0, u < source.width else { continue }
            let shade = 0.7 + 0.3 * cos(angle), lift = Int(bow * (1 - cos(angle)))
            for y in 0..<source.height {
                output[x, y + lift] = UInt8(Double(source[u, y]) * shade)
            }
        }
        let result = CIImage(cgImage: output.image)
        return result.transformed(by: CGAffineTransform(translationX: -result.extent.midX, y: -result.extent.midY))
    }

    /// A dark smudge over part of the code and a scratch across it.
    private func damaged(_ image: CIImage, random: inout SplitMix) -> CIImage {
        let box = image.extent.insetBy(dx: image.extent.width * 0.12, dy: image.extent.height * 0.12)
        let smudge = CGRect(x: box.minX + box.width * (0.15 + random.unit() * 0.55), y: box.minY + box.height * (0.5 + random.unit() * 0.2),
                            width: box.width * 0.16, height: box.height * 0.32)
        let dark = CIImage(color: CIColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 0.85)).cropped(to: smudge)
            .applyingGaussianBlur(sigma: 3).cropped(to: smudge.insetBy(dx: -6, dy: -6))
        let scratch = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            .cropped(to: CGRect(x: box.minX - box.width * 0.1, y: box.minY + box.height * (0.15 + random.unit() * 0.2),
                                width: box.width * 1.2, height: max(2, box.height * 0.05)))
        return scratch.composited(over: dark.composited(over: image)).cropped(to: image.extent)
    }

    // MARK: Report

    private func table(hits: [String: [Condition: Int]], totals: [String: Int], order: [String]) -> String {
        var seen = Set<String>()
        let symbologies = order.filter { seen.insert($0).inserted }
        var lines = ["| Symbology | n | " + Condition.allCases.map(\.rawValue).joined(separator: " | ") + " |",
                     "| --- | ---: | " + Condition.allCases.map { _ in "---:" }.joined(separator: " | ") + " |"]
        var overall: [Condition: (Int, Int)] = [:]
        for symbology in symbologies {
            let total = totals[symbology] ?? 0
            let cells = Condition.allCases.map { condition -> String in
                let hit = hits[symbology]?[condition] ?? 0
                overall[condition, default: (0, 0)].0 += hit
                overall[condition, default: (0, 0)].1 += total
                return "\(Int((Double(hit) / Double(max(total, 1)) * 100).rounded()))%"
            }
            lines.append("| \(symbology) | \(total) | " + cells.joined(separator: " | ") + " |")
        }
        let all = Condition.allCases.map { condition -> String in
            let (hit, total) = overall[condition] ?? (0, 1)
            return "\(Int((Double(hit) / Double(max(total, 1)) * 100).rounded()))%"
        }
        lines.append("| All | \(totals.values.reduce(0, +)) | " + all.joined(separator: " | ") + " |")
        return lines.joined(separator: "\n")
    }
}

/// Repeatable randomness for the benchmark.
fileprivate struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int(truncatingIfNeeded: (z ^ (z >> 31)) >> 1)
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

/// An 8-bit grey bitmap, origin top left.
fileprivate final class Gray {
    let width: Int, height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: UInt8) {
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.pixels = pixels
    }

    /// Standard normal values ×2.55 (σ = 1% of full scale), drawn once.
    private static let noise: [Float] = {
        var random = SplitMix(seed: 7)
        return (0..<(1 << 20)).map { _ in
            let u = max(random.unit(), 1e-9), v = random.unit()
            return Float(sqrt(-2 * log(u)) * cos(2 * .pi * v) * 2.55)
        }
    }()

    /// Adds `scale` × 1% Gaussian noise, reading the table from `start`.
    func addNoise(scale: Float, start: Int) {
        let table = Self.noise
        let mask = table.count - 1
        var index = start & mask
        pixels.withUnsafeMutableBufferPointer { buffer in
            table.withUnsafeBufferPointer { noise in
                for pixel in 0..<buffer.count {
                    buffer[pixel] = UInt8(max(0, min(255, Float(buffer[pixel]) + noise[index] * scale)))
                    index = (index &+ 7919) & mask
                }
            }
        }
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { if x >= 0, x < width, y >= 0, y < height { pixels[y * width + x] = newValue } }
    }

    var image: CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
