#if canImport(Vision)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Reads product codes from camera frames or images with Vision, refusing
/// any whose check digit fails. The camera, the simulator's stand-in feed and
/// the scanner benchmark all decode here. See docs/BARCODE.md.
public final class BarcodeDecoder {
    /// Every retail symbology Vision reads. ITF-14 often arrives as
    /// Interleaved 2 of 5; only its 14-digit form is accepted.
    public static let symbologies: [VNBarcodeSymbology] = [
        .ean13, .ean8, .upce, .itf14, .i2of5, .code128, .gs1DataBar, .gs1DataBarLimited, .gs1DataBarExpanded,
        .qr, .microQR, .dataMatrix,
    ]

    public struct Frame: Sendable {
        public var codes: [ScannedCode] = []
        /// Codes that decoded but failed their check digit or length.
        public var rejected = 0
        /// Short codes too small in the frame to trust: hold the phone closer.
        public var tooSmall = 0
        /// Everything Vision reported, as "symbology payload box", for diagnosis.
        public var observations: [String] = []
    }

    private var request: VNDetectBarcodesRequest
    private var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init() {
        request = Self.request(revision: nil)
    }

    /// The Vision revision in use: the newest, except where it has no
    /// inference context (the iOS simulator), which falls back to the first.
    public var revision: Int { request.revision }

    /// Normalised, upright, origin lower left, as Vision takes it.
    public var regionOfInterest: CGRect {
        get { region }
        set { region = newValue; request.regionOfInterest = newValue }
    }

    public func decode(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Frame {
        var size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) { size = CGSize(width: size.height, height: size.width) }
        return perform(size: size) { VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation) }
    }

    public func decode(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) -> Frame {
        var size = CGSize(width: image.width, height: image.height)
        if [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) { size = CGSize(width: size.height, height: size.width) }
        return perform(size: size) { VNImageRequestHandler(cgImage: image, orientation: orientation) }
    }

    private static func request(revision: Int?) -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest()
        if let revision { request.revision = revision }
        let supported = Set((try? request.supportedSymbologies()) ?? [])
        request.symbologies = symbologies.filter(supported.contains)
        return request
    }

    /// `size` is the upright image's, in pixels, for each symbol's shape.
    private func perform(size: CGSize, _ handler: () -> VNImageRequestHandler) -> Frame {
        do {
            try handler().perform([request])
        } catch let error as NSError where error.domain == VNErrorDomain && error.code == VNErrorCode.internalError.rawValue
                    && request.revision != 1 {
            // "Could not create inference context": no neural engine or GPU for
            // the newer revisions, as in the iOS simulator.
            request = Self.request(revision: 1)
            request.regionOfInterest = region
            do { try handler().perform([request]) } catch { return Frame() }
        } catch {
            return Frame()
        }
        return Self.frame(request.results ?? [], size: size)
    }

    public static func frame(_ observations: [VNBarcodeObservation], size: CGSize) -> Frame {
        var frame = Frame()
        for observation in observations {
            let width = Self.width(observation, size: size)
            frame.observations.append("\(observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")) "
                + "\(observation.payloadStringValue ?? "-") \(observation.boundingBox.integral(scale: 1000)) \(Int(width)) px")
            guard let payload = observation.payloadStringValue, let symbology = symbology(observation.symbology) else { continue }
            switch BarcodePayload.read(payload, as: symbology) {
            case .success where !BarcodeLegibility.isLegible(symbology, width: width): frame.tooSmall += 1
            case .success(let code): frame.codes.append(code)
            case .failure: frame.rejected += 1
            }
        }
        return frame
    }

    /// The symbol's width along its own axis, in pixels: the longer of its
    /// top and bottom edges, so tilt and rotation don't shrink it.
    static func width(_ observation: VNBarcodeObservation, size: CGSize) -> Double {
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot((b.x - a.x) * size.width, (b.y - a.y) * size.height)) }
        return max(distance(observation.topLeft, observation.topRight), distance(observation.bottomLeft, observation.bottomRight))
    }

    public static func symbology(_ symbology: VNBarcodeSymbology) -> BarcodeSymbology? {
        switch symbology {
        case .ean13: .ean13
        case .ean8: .ean8
        case .upce: .upcE
        case .itf14, .i2of5: .itf14
        case .code128: .code128
        case .gs1DataBar: .dataBar
        case .gs1DataBarLimited: .dataBarLimited
        case .gs1DataBarExpanded: .dataBarExpanded
        case .qr: .qr
        case .microQR: .microQR
        case .dataMatrix: .dataMatrix
        default: nil
        }
    }
}
private extension CGRect {
    func integral(scale: CGFloat) -> String {
        "(\(Int(minX * scale)),\(Int(minY * scale)) \(Int(width * scale))×\(Int(height * scale)))"
    }
}
#endif
