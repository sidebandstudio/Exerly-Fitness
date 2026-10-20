#if canImport(CoreImage)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Synthetic codes drawn as they'd be printed on a pack: black modules on a
/// white label with its quiet zone. Only the simulator's stand-in camera and
/// the scanner benchmark use these.
public enum SyntheticBarcode {
    /// A payload as a test writes it: `<symbology>:<data>`, such as
    /// `ean13:0012345678905`, `upce:04252614`, `gs1128:(01)09506000134352(3103)000512`,
    /// `databar:09506000134352` or `qr:https://id.gs1.org/01/09506000134352`.
    public static func image(for payload: String, module: Int = 4) -> CGImage? {
        guard let colon = payload.firstIndex(of: ":") else { return nil }
        let kind = payload[..<colon].lowercased(), data = String(payload[payload.index(after: colon)...])
        if kind == "qr" { return qr(data, module: module * 2) }
        return bars(kind: kind, data: data).map { image($0, module: module) }
    }

    public static func bars(kind: String, data: String) -> BarcodeBars? {
        switch kind {
        case "ean13": BarcodeEncoder.ean13(data)
        case "upca": BarcodeEncoder.upcA(data)
        case "ean8": BarcodeEncoder.ean8(data)
        case "upce": BarcodeEncoder.upcE(data)
        case "itf14": BarcodeEncoder.itf14(data)
        case "databar": BarcodeEncoder.dataBar(data)
        case "databarstacked": BarcodeEncoder.dataBarStacked(data)
        case "gs1128": gs1128(data)
        default: nil
        }
    }

    /// GS1-128 from a parenthesised element string.
    public static func gs1128(_ text: String) -> BarcodeBars? {
        var fields: [(ai: String, value: String)] = []
        for part in text.split(separator: "(").map(String.init) {
            let pieces = part.split(separator: ")", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            fields.append((pieces[0], pieces[1]))
        }
        return BarcodeEncoder.gs1128(fields, variableLength: ["10", "21"])
    }

    public static func image(_ bars: BarcodeBars, module m: Int = 4) -> CGImage {
        let pad = 4, bearer = bars.bearer ? 4 : 0, quiet = bars.quietZone
        let width = (pad + bearer + quiet) * 2 + bars.width, height = (pad + bearer) * 2 + bars.height
        let context = CGContext(data: nil, width: width * m, height: height * m, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.scaleBy(x: CGFloat(m), y: CGFloat(m))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if bearer > 0 {
            // ITF-14's bearer bars frame the symbol and its quiet zones.
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: pad, y: pad, width: width - pad * 2, height: height - pad * 2))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: pad + bearer, y: pad + bearer, width: width - (pad + bearer) * 2, height: height - (pad + bearer) * 2))
        }
        context.setFillColor(gray: 0, alpha: 1)
        let left = pad + bearer + quiet
        var top = height - pad - bearer
        for row in bars.rows {
            top -= row.height
            var start: Int?
            for index in 0...row.modules.count {
                let dark = index < row.modules.count && row.modules[index]
                if dark, start == nil { start = index }
                if !dark, let first = start {
                    context.fill(CGRect(x: left + first, y: top, width: index - first, height: row.height))
                    start = nil
                }
            }
        }
        return context.makeImage()!
    }

    public static func qr(_ text: String, module: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Four modules of quiet zone, then scaled without smoothing.
        let padded = output.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -4, dy: -4).offsetBy(dx: 4, dy: 4)))
            .samplingNearest().transformed(by: CGAffineTransform(scaleX: CGFloat(module), y: CGFloat(module)))
        return CIContext().createCGImage(padded, from: padded.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
#endif
