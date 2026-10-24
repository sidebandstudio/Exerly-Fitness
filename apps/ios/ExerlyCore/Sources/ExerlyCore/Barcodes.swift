import CoreGraphics
import Foundation

/// A trade item number in its canonical 14-digit form (GTIN-14). UPC-A,
/// UPC-E, EAN-8, EAN-13 and ITF-14 codes for one product share one key, so a
/// product scanned as UPC-A finds the one stored as EAN-13. See docs/BARCODE.md.
public struct GTIN: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Fourteen digits, the last a valid GS1 check digit.
    public let key: String

    /// A GTIN-8, -12, -13 or -14 written with or without leading zeros. Nil
    /// for anything else, or when the check digit is wrong.
    public init?(_ digits: some StringProtocol) {
        let digits = String(digits)
        guard (8...14).contains(digits.count), digits.allSatisfy(\.isASCIIDigit) else { return nil }
        let key = String(repeating: "0", count: 14 - digits.count) + digits
        guard Self.hasValidCheckDigit(key) else { return nil }
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let gtin = GTIN(raw), raw.count == 14 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a GTIN-14: \(raw)"))
        }
        self = gtin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }

    public static func < (a: GTIN, b: GTIN) -> Bool { a.key < b.key }
    public var description: String { display }

    // MARK: Check digits

    /// The GS1 mod-10 check digit for the digits before it.
    public static func checkDigit(of body: some StringProtocol) -> Int? {
        checkDigit(Array(body.utf8))
    }

    /// True when the last digit is the check digit of the others.
    public static func hasValidCheckDigit(_ digits: some StringProtocol) -> Bool {
        let bytes = Array(digits.utf8)
        guard bytes.count >= 2, let check = checkDigit(bytes.dropLast()), isDigit(bytes.last!) else { return false }
        return check == Int(bytes.last! - zero)
    }

    private static let zero = UInt8(ascii: "0")
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= zero + 9 }

    private static func checkDigit(_ body: some Collection<UInt8>) -> Int? {
        guard !body.isEmpty else { return nil }
        var sum = 0, weight = 3
        for byte in body.reversed() {
            guard isDigit(byte) else { return nil }
            sum += Int(byte - zero) * weight
            weight = 4 - weight
        }
        return (10 - sum % 10) % 10
    }

    // MARK: UPC-E

    /// The 12-digit UPC-A a UPC-E code stands for, by the GS1 zero-suppression
    /// rules. Takes the six data digits (number system 0, check computed), seven
    /// (number system first) or all eight; an eighth digit must be the check
    /// digit of the expansion. Nil for anything else.
    public static func expandUPCE(_ code: some StringProtocol) -> String? {
        let code = Array(code.utf8)
        guard code.allSatisfy(isDigit) else { return nil }
        let system: UInt8, data: ArraySlice<UInt8>, check: UInt8?
        switch code.count {
        case 6: (system, data, check) = (zero, code[0...5], nil)
        case 7: (system, data, check) = (code[0], code[1...6], nil)
        case 8: (system, data, check) = (code[0], code[1...6], code[7])
        default: return nil
        }
        guard system == zero || system == zero + 1 else { return nil }
        let d = Array(data), o = zero
        let body: [UInt8]
        switch d[5] - zero {
        case 0...2: body = [system, d[0], d[1], d[5], o, o, o, o, d[2], d[3], d[4]]
        case 3: body = [system, d[0], d[1], d[2], o, o, o, o, o, d[3], d[4]]
        case 4: body = [system, d[0], d[1], d[2], d[3], o, o, o, o, o, d[4]]
        default: body = [system, d[0], d[1], d[2], d[3], d[4], o, o, o, o, d[5]]
        }
        let computed = zero + UInt8(checkDigit(body)!)
        if let check, check != computed { return nil }
        return String(decoding: body + [computed], as: UTF8.self)
    }

    /// The 8-digit UPC-E for a UPC-A that zero-suppresses, or nil. The inverse
    /// of `expandUPCE`, choosing the form GS1 prints.
    public static func compressUPCA(_ upcA: some StringProtocol) -> String? {
        let c = Array(upcA.utf8), o = zero
        guard c.count == 12, hasValidCheckDigit(upcA), c[0] == o || c[0] == o + 1 else { return nil }
        // Manufacturer c[1...5], product c[6...10].
        let data: [UInt8]
        if c[3] <= o + 2, c[4] == o, c[5] == o, c[6] == o, c[7] == o {
            data = [c[1], c[2], c[8], c[9], c[10], c[3]]
        } else if c[4] == o, c[5] == o, c[6] == o, c[7] == o, c[8] == o {
            data = [c[1], c[2], c[3], c[9], c[10], o + 3]
        } else if c[5] == o, c[6...9].allSatisfy({ $0 == o }) {
            data = [c[1], c[2], c[3], c[4], c[10], o + 4]
        } else if c[6...9].allSatisfy({ $0 == o }), c[10] >= o + 5 {
            data = [c[1], c[2], c[3], c[4], c[5], c[10]]
        } else {
            return nil
        }
        let upcE = String(decoding: [c[0]] + data + [c[11]], as: UTF8.self)
        return expandUPCE(upcE) == String(upcA) ? upcE : nil
    }

    // MARK: Forms

    /// The 13-digit form, when the indicator digit is 0.
    public var gtin13: String? { key.first == "0" ? String(key.dropFirst()) : nil }
    /// The 12-digit UPC-A form, when it has one.
    public var upcA: String? { key.hasPrefix("00") ? String(key.dropFirst(2)) : nil }
    /// The 8-digit form, when it has one.
    public var gtin8: String? { key.hasPrefix("000000") ? String(key.dropFirst(6)) : nil }

    /// The form printed under the bars: 8, 12, 13 or 14 digits.
    public var display: String { gtin8 ?? upcA ?? gtin13 ?? key }

    /// The code Open Food Facts files the product under, as the server asks
    /// for it.
    public var openFoodFacts: String {
        guard let gtin13 else { return key }
        return gtin13.hasPrefix("00000") ? String(gtin13.dropFirst(5)) : gtin13
    }

    // MARK: Kinds

    /// What a code identifies, by its GS1 prefix.
    public enum Kind: Hashable, Sendable {
        /// A product with one identity everywhere: look it up.
        case product
        /// An in-store label for a weighed or priced item: the item number is
        /// the store's own, and the rest carries its price or weight.
        case variableMeasure(itemReference: String, embeddedValue: String)
        /// A number a company issues for use in its own stores: GTIN-13 prefixes
        /// 040–049, and EAN-8s starting 0 or 2 (GS1 General Specifications,
        /// restricted circulation numbers). Two retailers can use one for
        /// different foods.
        case storeInternal
        /// A coupon or refund receipt (050–059, 980–984, 99).
        case coupon
        /// A book, magazine or sheet music (977–979).
        case publication
    }

    public var kind: Kind {
        guard let thirteen = gtin13 else {
            // Indicator 9 marks a variable-measure trade item.
            return key.first == "9" ? .variableMeasure(itemReference: String(key.dropFirst().prefix(12)), embeddedValue: "") : .product
        }
        if let eight = gtin8 { return eight.first == "0" || eight.first == "2" ? .storeInternal : .product }
        let digits = Array(thirteen)
        let prefix = Int(String(digits[0...2]))!
        switch prefix {
        case 20...29:
            // A UPC-A in number system 2: 2 IIIII VVVVV C.
            return .variableMeasure(itemReference: String(digits[2...6]), embeddedValue: String(digits[7...11]))
        case 200...299:
            // An EAN-13 in 20–29: 2X IIIII VVVVV C, its split set by each country.
            return .variableMeasure(itemReference: String(digits[2...6]), embeddedValue: String(digits[7...11]))
        case 40...49: return .storeInternal
        case 50...59, 980...984, 990...999: return .coupon
        case 977...979: return .publication
        default: return .product
        }
    }

    /// Whether a food database can know this code.
    public var isProduct: Bool { kind == .product }

    // MARK: Typed digits

    /// Every code a person could mean by typing these digits under a
    /// barcode, most likely first, and products before any other kind. Leading
    /// zeros may be left off. Eight digits can be an EAN-8 or a UPC-E, so both
    /// are tried when both check out; six or seven digits are read as a UPC-E
    /// printed without its check digit or number system.
    public static func candidates(typed text: String) -> [GTIN] {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.allSatisfy(\.isASCIIDigit), (6...14).contains(digits.count) else { return [] }
        var found: [GTIN] = []
        if digits.count >= 8, let gtin = GTIN(digits) { found.append(gtin) }
        if (6...8).contains(digits.count), let expanded = expandUPCE(digits), let gtin = GTIN(expanded), !found.contains(gtin) {
            found.append(gtin)
        }
        return found.filter(\.isProduct) + found.filter { !$0.isProduct }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Scanned codes

/// A symbology a scanner reports.
public enum BarcodeSymbology: String, Codable, Sendable, CaseIterable {
    case ean13, ean8, upcA, upcE, itf14, code128, dataBar, dataBarStacked, dataBarLimited, dataBarExpanded
    case qr, microQR, dataMatrix
    /// Digits a person typed.
    case typed

    public var title: String {
        switch self {
        case .ean13: "EAN-13"
        case .ean8: "EAN-8"
        case .upcA: "UPC-A"
        case .upcE: "UPC-E"
        case .itf14: "ITF-14"
        case .code128: "GS1-128"
        case .dataBar: "GS1 DataBar"
        case .dataBarStacked: "GS1 DataBar Stacked"
        case .dataBarLimited: "GS1 DataBar Limited"
        case .dataBarExpanded: "GS1 DataBar Expanded"
        case .qr: "QR"
        case .microQR: "Micro QR"
        case .dataMatrix: "Data Matrix"
        case .typed: "Typed"
        }
    }
}

/// A code accepted from a scan: its product number and anything else its
/// GS1 data carried.
public struct ScannedCode: Hashable, Sendable {
    public var gtin: GTIN
    public var symbology: BarcodeSymbology
    /// Net weight from GS1 application identifiers 310n or 320n.
    public var netWeightGrams: Double?

    public init(gtin: GTIN, symbology: BarcodeSymbology, netWeightGrams: Double? = nil) {
        self.gtin = gtin
        self.symbology = symbology
        self.netWeightGrams = netWeightGrams
    }
}

/// Why a scanner's payload isn't a product code.
public enum BarcodeReadFailure: Error, Hashable, Sendable {
    /// The digits fail their check digit: a misread or a damaged print.
    case checkDigit
    /// The wrong number of digits for its symbology.
    case length
    /// Data, such as a web address, that carries no GTIN.
    case noGTIN
}

/// Turns what a scanner decoded into a product number, refusing misreads.
public enum BarcodePayload {
    public static func read(_ payload: String, as symbology: BarcodeSymbology) -> Result<ScannedCode, BarcodeReadFailure> {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        switch symbology {
        case .ean13: return digits(text, lengths: [13], symbology)
        case .ean8: return digits(text, lengths: [8], symbology)
        case .upcA: return digits(text, lengths: [12], symbology)
        case .itf14: return digits(text, lengths: [14], symbology)
        case .upcE:
            guard text.allSatisfy(\.isASCIIDigit), (6...8).contains(text.count) else { return .failure(.length) }
            guard let expanded = GTIN.expandUPCE(text), let gtin = GTIN(expanded) else { return .failure(.checkDigit) }
            return .success(ScannedCode(gtin: gtin, symbology: .upcE))
        case .typed:
            guard let gtin = GTIN.candidates(typed: text).first else { return .failure(.checkDigit) }
            return .success(ScannedCode(gtin: gtin, symbology: .typed))
        case .dataBar, .dataBarStacked, .dataBarLimited:
            // These carry only (01): written with or without the AI, or as 13 digits
            // whose check digit the symbol implies.
            if let element = elementString(text, symbology) { return element }
            if text.count == 13, text.allSatisfy(\.isASCIIDigit), let check = GTIN.checkDigit(of: text),
               let gtin = GTIN(text + String(check)) {
                return .success(ScannedCode(gtin: gtin, symbology: symbology))
            }
            return digits(text, lengths: [14], symbology)
        case .code128, .dataBarExpanded, .dataMatrix:
            if let element = elementString(text, symbology) { return element }
            return plainDigits(text, symbology)
        case .qr, .microQR:
            if let link = digitalLink(text) {
                guard let gtin = GTIN(link) else { return .failure(.checkDigit) }
                return .success(ScannedCode(gtin: gtin, symbology: symbology))
            }
            if let element = elementString(text, symbology) { return element }
            return plainDigits(text, symbology)
        }
    }

    private static func digits(_ text: String, lengths: Set<Int>, _ symbology: BarcodeSymbology) -> Result<ScannedCode, BarcodeReadFailure> {
        guard text.allSatisfy(\.isASCIIDigit), lengths.contains(text.count) else { return .failure(.length) }
        guard let gtin = GTIN(text) else { return .failure(.checkDigit) }
        return .success(ScannedCode(gtin: gtin, symbology: symbology))
    }

    /// A 2D or Code 128 symbol holding just a GTIN's digits.
    private static func plainDigits(_ text: String, _ symbology: BarcodeSymbology) -> Result<ScannedCode, BarcodeReadFailure> {
        guard text.allSatisfy(\.isASCIIDigit), [8, 12, 13, 14].contains(text.count) else { return .failure(.noGTIN) }
        guard let gtin = GTIN(text) else { return .failure(.checkDigit) }
        return .success(ScannedCode(gtin: gtin, symbology: symbology))
    }

    // MARK: GS1 element strings

    /// The (01) GTIN and net weight in a GS1 element string, raw (FNC1 as the
    /// group separator) or written with parentheses. Nil when it holds no (01)
    /// or (02); a failure when that GTIN's check digit is wrong.
    static func elementString(_ text: String, _ symbology: BarcodeSymbology) -> Result<ScannedCode, BarcodeReadFailure>? {
        guard let fields = applicationIdentifiers(text) else { return nil }
        guard let raw = fields["01"] ?? fields["02"] else { return nil }
        guard raw.count == 14, let gtin = GTIN(raw) else { return .failure(.checkDigit) }
        var weight: Double?
        for (ai, value) in fields where ai.count == 4 && value.count == 6 {
            guard let decimals = Int(String(ai.last!)), decimals <= 5, let number = Double(value) else { continue }
            let amount = number / pow(10, Double(decimals))
            if ai.hasPrefix("310") { weight = amount * 1000 }
            if ai.hasPrefix("320") { weight = amount * 453.59237 }
        }
        return .success(ScannedCode(gtin: gtin, symbology: symbology, netWeightGrams: weight))
    }

    /// Application identifiers and their values, or nil when the text isn't
    /// an element string.
    static func applicationIdentifiers(_ input: String) -> [String: String]? {
        var text = input
        // A symbology identifier such as ]C1, ]e0, ]d2 or ]Q3.
        if text.hasPrefix("]"), text.count >= 3 { text = String(text.dropFirst(3)) }
        if text.hasPrefix("(") { return parenthesized(text) }
        let separator: Character = "\u{1D}"
        text = String(text.drop { $0 == separator })
        let characters = Array(text)
        guard characters.count >= 4, characters[0...1].allSatisfy(\.isASCIIDigit) else { return nil }
        var fields: [String: String] = [:]
        var index = 0
        while index < characters.count {
            if characters[index] == separator { index += 1; continue }
            guard index + 2 <= characters.count, characters[index..<index + 2].allSatisfy(\.isASCIIDigit) else { return nil }
            let prefix = String(characters[index..<index + 2])
            if let total = predefinedLengths[prefix] {
                let aiLength = fourDigitPrefixes.contains(prefix) ? 4 : prefix == "41" ? 3 : 2
                guard index + total <= characters.count else { return nil }
                let ai = String(characters[index..<index + aiLength])
                fields[ai] = String(characters[index + aiLength..<index + total])
                index += total
            } else {
                // Variable length: runs to the next separator. Only fixed fields are read.
                var end = index
                while end < characters.count, characters[end] != separator { end += 1 }
                index = end
            }
        }
        return fields.isEmpty ? nil : fields
    }

    private static func parenthesized(_ text: String) -> [String: String]? {
        var fields: [String: String] = [:]
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[open...].firstIndex(of: ")") else { return nil }
            let ai = String(rest[rest.index(after: open)..<close])
            guard (2...4).contains(ai.count), ai.allSatisfy(\.isASCIIDigit) else { return nil }
            let valueEnd = rest[close...].dropFirst().firstIndex(of: "(") ?? rest.endIndex
            fields[ai] = String(rest[rest.index(after: close)..<valueEnd])
            rest = rest[valueEnd...]
        }
        return fields.isEmpty ? nil : fields
    }

    /// GS1's fixed-length element strings, by their first two digits: the
    /// length of AI and value together.
    private static let predefinedLengths: [String: Int] = [
        "00": 20, "01": 16, "02": 16, "03": 16, "04": 18, "11": 8, "12": 8, "13": 8, "14": 8, "15": 8,
        "16": 8, "17": 8, "18": 8, "19": 8, "20": 4, "31": 10, "32": 10, "33": 10, "34": 10, "35": 10,
        "36": 10, "41": 16,
    ]
    private static let fourDigitPrefixes: Set<String> = ["31", "32", "33", "34", "35", "36"]

    // MARK: GS1 Digital Link

    /// The GTIN digits in a GS1 Digital Link web address: the path segment
    /// after `01` or `gtin`. Nil for any other text.
    static func digitalLink(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        let segments = url.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        for (index, segment) in segments.enumerated().dropLast() where segment == "01" || segment.lowercased() == "gtin" {
            let value = segments[index + 1]
            guard value.allSatisfy(\.isASCIIDigit) else { return nil }
            return value
        }
        return nil
    }
}

/// Whether a decoded symbol was big enough in the frame to trust. Read at
/// about two pixels a module, a long code can decode as a short one: in the
/// benchmark, a small GS1 DataBar read as an EAN-8 whose check digit happened
/// to pass, twice. EAN-8 and UPC-E, with seven or eight digits under one check
/// digit, are only accepted from 2.5 pixels a module; closer, they read well.
public enum BarcodeLegibility {
    public static let minimumModule = 2.5

    /// Modules across a short symbol's bars, guards included.
    public static func modules(_ symbology: BarcodeSymbology) -> Int? {
        switch symbology {
        case .ean8: 67
        case .upcE: 51
        default: nil
        }
    }

    /// `width` is the symbol's width along its bars' axis, in pixels.
    public static func isLegible(_ symbology: BarcodeSymbology, width: Double) -> Bool {
        guard let modules = modules(symbology) else { return true }
        return width / Double(modules) >= minimumModule
    }
}

// MARK: - Accepting a read

/// Accepts a code only once it has been read the same way twice in a short
/// window, so a frame that misreads a digit never logs the wrong food. An
/// accepted code is held while it stays in view, and accepted again once it
/// has been out of view, so the second of two identical packs counts.
public struct BarcodeConsensus: Sendable {
    public var required: Int
    public var window: TimeInterval
    public var rearm: TimeInterval
    private var reads: [GTIN: [Date]] = [:]
    private var held: [GTIN: Date] = [:]
    private var resuming = false

    public init(required: Int = 2, window: TimeInterval = 1.2, rearm: TimeInterval = 1.0) {
        self.required = required
        self.window = window
        self.rearm = rearm
    }

    /// Feed every code one frame decoded. Returns the codes this frame accepted.
    public mutating func observe(_ codes: [ScannedCode], at time: Date) -> [ScannedCode] {
        if resuming {
            // Frames stopped while paused, so an absence wasn't seen: held codes
            // count as in view now, and must leave the frame to count again.
            for gtin in held.keys { held[gtin] = time }
            resuming = false
        }
        var accepted: [ScannedCode] = []
        var seen = Set<GTIN>()
        for code in codes where seen.insert(code.gtin).inserted {
            if let last = held[code.gtin] {
                if time.timeIntervalSince(last) <= rearm { held[code.gtin] = time; continue }
                held[code.gtin] = nil
            }
            var times = (reads[code.gtin] ?? []).filter { time.timeIntervalSince($0) <= window }
            times.append(time)
            if times.count >= required {
                reads[code.gtin] = nil
                held[code.gtin] = time
                accepted.append(code)
            } else {
                reads[code.gtin] = times
            }
        }
        reads = reads.filter { $0.value.contains { time.timeIntervalSince($0) <= window } }
        return accepted
    }

    /// Frames stop for a while, as under a sheet. Accepted codes stay held,
    /// so a pack still in view when frames resume isn't added again; it
    /// counts again only once it has been seen out of view.
    public mutating func pause() {
        reads = [:]
        resuming = true
    }

    /// Forgets every read and held code.
    public mutating func reset() {
        reads = [:]
        held = [:]
    }
}

// MARK: - Camera

public enum ScannerOptics {
    /// The zoom that lets a code of `minimumCodeSize` millimetres fill
    /// `previewFill` of the frame at the lens's closest focus, as Apple's
    /// barcode sample computes it, clamped to `range`. 1 when the code can be
    /// held close enough without zoom.
    public static func zoomFactor(minimumFocusDistance: Double, fieldOfView degrees: Double,
                                  minimumCodeSize: Double = 20, previewFill: Double,
                                  range: ClosedRange<Double> = 1...4) -> Double {
        guard minimumFocusDistance > 0, degrees > 0, degrees < 180, previewFill > 0 else { return range.lowerBound }
        let radians = degrees / 2 * .pi / 180
        let subjectDistance = (minimumCodeSize / previewFill) / tan(radians)
        guard subjectDistance < minimumFocusDistance else { return range.lowerBound }
        return min(max(minimumFocusDistance / subjectDistance, range.lowerBound), range.upperBound)
    }
}

extension ScannerOptics {
    /// The region Vision searches for a viewfinder window given in the
    /// sensor's normalised landscape frame, origin top left, as
    /// `metadataOutputRectConverted` returns it. Vision reads the portrait
    /// (`.right`) frame upright with its origin lower left. Padded by
    /// `padding` so a code half outside the window still reads; nil for an
    /// empty window.
    public static func visionRegion(sensor: CGRect, padding: Double = 0.08) -> CGRect? {
        guard sensor.width > 0, sensor.height > 0 else { return nil }
        let upright = CGRect(x: 1 - sensor.maxY, y: 1 - sensor.maxX, width: sensor.height, height: sensor.width)
        let region = upright.insetBy(dx: -padding, dy: -padding).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return region.isNull || region.isEmpty ? nil : region
    }
}

/// Suggests the light after the scene stays dark for a moment, and stops
/// once it brightens or the light is on. Brightness is the camera's EXIF
/// BrightnessValue (APEX): about 0 in a dim room, below −1 too dark to read bars.
public struct LowLightAdvisor: Sendable {
    public var dark: Double
    public var bright: Double
    public var sustain: TimeInterval
    public private(set) var suggesting = false
    private var since: Date?

    public init(dark: Double = -1, bright: Double = 0.5, sustain: TimeInterval = 1.2) {
        self.dark = dark
        self.bright = bright
        self.sustain = sustain
    }

    @discardableResult
    public mutating func observe(brightness: Double, at time: Date, torchOn: Bool) -> Bool {
        if torchOn { suggesting = false; since = nil; return false }
        let crossing = suggesting ? brightness > bright : brightness < dark
        if crossing {
            let start = since ?? time
            since = start
            if time.timeIntervalSince(start) >= sustain { suggesting.toggle(); since = nil }
        } else {
            since = nil
        }
        return suggesting
    }
}

/// The short credit shown with a database food, and where its full terms are.
public enum FoodDataCredit {
    /// "Open Food Facts · ODbL" for Open Food Facts's attribution line, with a
    /// link to it; any other line as it is, with the first web address in it.
    public static func short(_ attribution: String) -> (label: String, url: URL?) {
        if attribution.localizedCaseInsensitiveContains("Open Food Facts") {
            return ("Open Food Facts · ODbL", URL(string: "https://world.openfoodfacts.org"))
        }
        if attribution.localizedCaseInsensitiveContains("FoodData Central") || attribution.contains("USDA") {
            return ("USDA FoodData Central", URL(string: "https://fdc.nal.usda.gov"))
        }
        let address = attribution.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "," })
            .first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
        return (attribution, address.flatMap { URL(string: String($0)) })
    }
}
