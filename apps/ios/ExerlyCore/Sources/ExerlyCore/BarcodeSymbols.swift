import Foundation

/// The bars of a barcode, module by module: what the scanner benchmark and
/// the simulator's stand-in camera draw. 2D codes come from Core Image.
public struct BarcodeBars: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        /// True for a dark module.
        public var modules: [Bool]
        /// In modules.
        public var height: Int
    }

    public var rows: [Row]
    /// Light modules required either side.
    public var quietZone: Int
    /// ITF-14's frame, which stops a short scan reading part of the code.
    public var bearer: Bool

    public var width: Int { rows.map(\.modules.count).max() ?? 0 }
    public var height: Int { rows.reduce(0) { $0 + $1.height } }

    init(_ modules: [Bool], height: Int, quietZone: Int, bearer: Bool = false) {
        rows = [Row(modules: modules, height: height)]
        self.quietZone = quietZone
        self.bearer = bearer
    }

    init(rows: [Row], quietZone: Int) {
        self.rows = rows
        self.quietZone = quietZone
        bearer = false
    }
}

/// Encoders for the retail symbologies. Each returns nil for data the
/// symbology can't carry. Inputs include their check digits.
public enum BarcodeEncoder {
    // MARK: EAN and UPC

    private static let lCodes = ["0001101", "0011001", "0010011", "0111101", "0100011",
                                 "0110001", "0101111", "0111011", "0110111", "0001011"]
    /// Which of the left half's six digits use the G (even) set, by EAN-13's first digit.
    private static let ean13Parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                                      "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
    /// UPC-E's parity for number system 0, by check digit; system 1 inverts it.
    private static let upcEParity = ["EEEOOO", "EEOEOO", "EEOOEO", "EEOOOE", "EOEEOO",
                                     "EOOEEO", "EOOOEE", "EOEOEO", "EOEOOE", "EOOEOE"]

    private static func bits(_ pattern: String) -> [Bool] { pattern.map { $0 == "1" } }
    private static func l(_ digit: Int) -> [Bool] { bits(lCodes[digit]) }
    private static func r(_ digit: Int) -> [Bool] { l(digit).map { !$0 } }
    private static func g(_ digit: Int) -> [Bool] { r(digit).reversed() }
    private static func digits(_ text: String, count: Int) -> [Int]? {
        guard text.count == count, GTIN.hasValidCheckDigit(text) else { return nil }
        return text.map { Int(String($0))! }
    }

    public static func ean13(_ code: String) -> BarcodeBars? {
        guard let d = digits(code, count: 13) else { return nil }
        let parity = Array(ean13Parity[d[0]])
        var modules = bits("101")
        for index in 1...6 { modules += parity[index - 1] == "L" ? l(d[index]) : g(d[index]) }
        modules += bits("01010")
        for index in 7...12 { modules += r(d[index]) }
        modules += bits("101")
        return BarcodeBars(modules, height: 70, quietZone: 11)
    }

    /// A UPC-A's bars are those of the EAN-13 with a leading zero.
    public static func upcA(_ code: String) -> BarcodeBars? {
        code.count == 12 ? ean13("0" + code) : nil
    }

    public static func ean8(_ code: String) -> BarcodeBars? {
        guard let d = digits(code, count: 8) else { return nil }
        var modules = bits("101")
        for index in 0...3 { modules += l(d[index]) }
        modules += bits("01010")
        for index in 4...7 { modules += r(d[index]) }
        modules += bits("101")
        return BarcodeBars(modules, height: 55, quietZone: 7)
    }

    /// Eight digits: number system, six data digits, and the check digit of
    /// the UPC-A it expands to.
    public static func upcE(_ code: String) -> BarcodeBars? {
        guard code.count == 8, GTIN.expandUPCE(code) != nil else { return nil }
        let d = code.map { Int(String($0))! }
        let parity = Array(upcEParity[d[7]]).map { d[0] == 0 ? $0 : ($0 == "E" ? "O" : "E") }
        var modules = bits("101")
        for index in 1...6 { modules += parity[index - 1] == "O" ? l(d[index]) : g(d[index]) }
        modules += bits("010101")
        return BarcodeBars(modules, height: 55, quietZone: 9)
    }

    // MARK: ITF-14

    private static let itfPatterns = ["NNWWN", "WNNNW", "NWNNW", "WWNNN", "NNWNW",
                                      "WNWNN", "NWWNN", "NNNWW", "WNNWN", "NWNWN"]

    /// Interleaved 2 of 5 with wide elements 2.5 times the narrow, framed by bearer bars.
    public static func itf14(_ code: String) -> BarcodeBars? {
        guard let d = digits(code, count: 14) else { return nil }
        let narrow = 2, wide = 5
        var modules: [Bool] = []
        func element(_ dark: Bool, _ width: Int) { modules += Array(repeating: dark, count: width) }
        for dark in [true, false, true, false] { element(dark, narrow) }
        for pair in stride(from: 0, to: 14, by: 2) {
            let bars = Array(itfPatterns[d[pair]]), spaces = Array(itfPatterns[d[pair + 1]])
            for index in 0..<5 {
                element(true, bars[index] == "W" ? wide : narrow)
                element(false, spaces[index] == "W" ? wide : narrow)
            }
        }
        element(true, wide)
        element(false, narrow)
        element(true, narrow)
        return BarcodeBars(modules, height: 64, quietZone: 20, bearer: true)
    }

    // MARK: Code 128

    /// Bar and space widths of Code 128's 106 symbols, then the stop.
    private static let code128 = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
        "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
        "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
        "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
        "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
        "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
        "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
        "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
    ]

    /// GS1-128: FNC1 then the element string's digits in code set C. Pass
    /// application identifiers and values; variable-length values other
    /// than the last are ended with FNC1.
    public static func gs1128(_ fields: [(ai: String, value: String)], variableLength: Set<String> = []) -> BarcodeBars? {
        let fnc1 = 102
        var values = [105, fnc1]
        for (index, field) in fields.enumerated() {
            let text = field.ai + field.value
            guard text.allSatisfy(\.isASCIIDigit), text.count % 2 == 0 else { return nil }
            var position = text.startIndex
            while position < text.endIndex {
                let next = text.index(position, offsetBy: 2)
                values.append(Int(text[position..<next])!)
                position = next
            }
            if variableLength.contains(field.ai), index < fields.count - 1 { values.append(fnc1) }
        }
        let check = values.enumerated().reduce(values[0]) { sum, item in item.offset == 0 ? sum : sum + item.offset * item.element } % 103
        values += [check, 106]
        var modules: [Bool] = []
        for value in values {
            for (index, width) in code128[value].enumerated() {
                modules += Array(repeating: index % 2 == 0, count: Int(String(width))!)
            }
        }
        return BarcodeBars(modules, height: 40, quietZone: 10)
    }

    // MARK: GS1 DataBar

    private static let gSum = [0, 161, 961, 2015, 2715, 0, 336, 1036, 1516]
    private static let tTable = [1, 10, 34, 70, 126, 4, 20, 48, 81]
    private static let modulesOdd = [12, 10, 8, 6, 4, 5, 7, 9, 11]
    private static let modulesEven = [4, 6, 8, 10, 12, 10, 8, 6, 4]
    private static let widestOdd = [8, 6, 4, 3, 1, 2, 4, 6, 8]
    private static let widestEven = [1, 3, 5, 6, 8, 7, 5, 3, 1]
    /// 3^n mod 79, in the order the characters' widths are summed.
    private static let checksumWeights = (0..<32).map { power in (0..<power).reduce(1) { value, _ in value * 3 % 79 } }
    private static let finderPatterns = [[3, 8, 2, 1, 1], [3, 5, 5, 1, 1], [3, 3, 7, 1, 1], [3, 1, 9, 1, 1], [2, 7, 4, 1, 1],
                                         [2, 5, 6, 1, 1], [2, 3, 8, 1, 1], [1, 5, 7, 1, 1], [1, 3, 9, 1, 1]]

    /// The element widths of GS1 DataBar Omnidirectional for a GTIN-14,
    /// guards included: 46 elements over 96 modules, starting with a space.
    static func dataBarWidths(_ code: String) -> [Int]? {
        guard code.count == 14, GTIN.hasValidCheckDigit(code), let value = Int(code.prefix(13)) else { return nil }
        let left = value / 4_537_077, right = value % 4_537_077
        let characters = [left / 1597, left % 1597, right / 1597, right % 1597]
        var widths = Array(repeating: [Int](repeating: 0, count: 4), count: 8)
        for (index, character) in characters.enumerated() {
            let outside = index % 2 == 0
            let group = outside
                ? [160, 960, 2014, 2714, 2840].firstIndex { character <= $0 }!
                : 5 + [335, 1035, 1515, 1596].firstIndex { character <= $0 }!
            let offset = character - gSum[group]
            let odd = outside ? offset / tTable[group] : offset % tTable[group]
            let even = outside ? offset % tTable[group] : offset / tTable[group]
            let oddWidths = elementWidths(odd, modules: modulesOdd[group], elements: 4, widest: widestOdd[group], noNarrow: outside)
            let evenWidths = elementWidths(even, modules: modulesEven[group], elements: 4, widest: widestEven[group], noNarrow: !outside)
            for element in 0..<4 {
                widths[element * 2][index] = oddWidths[element]
                widths[element * 2 + 1][index] = evenWidths[element]
            }
        }
        var checksum = 0
        for element in 0..<8 {
            for character in 0..<4 { checksum += checksumWeights[element + 8 * character] * widths[element][character] }
        }
        checksum %= 79
        if checksum >= 8 { checksum += 1 }
        if checksum >= 72 { checksum += 1 }
        var total = Array(repeating: 1, count: 46)
        for element in 0..<8 {
            total[element + 2] = widths[element][0]
            total[element + 15] = widths[7 - element][1]
            total[element + 23] = widths[element][3]
            total[element + 36] = widths[7 - element][2]
        }
        for element in 0..<5 {
            total[element + 10] = finderPatterns[checksum / 9][element]
            total[element + 31] = finderPatterns[checksum % 9][4 - element]
        }
        return total
    }

    private static func modules(_ widths: some Sequence<Int>, startingDark: Bool) -> [Bool] {
        var modules: [Bool] = []
        var dark = startingDark
        for width in widths {
            modules += Array(repeating: dark, count: width)
            dark.toggle()
        }
        return modules
    }

    /// GS1 DataBar Omnidirectional.
    public static func dataBar(_ code: String) -> BarcodeBars? {
        guard let widths = dataBarWidths(code) else { return nil }
        return BarcodeBars(modules(widths, startingDark: false), height: 33, quietZone: 2)
    }

    /// GS1 DataBar Stacked Omnidirectional: the two halves in rows of 33
    /// modules' height, with three separator rows between them.
    public static func dataBarStacked(_ code: String) -> BarcodeBars? {
        guard let widths = dataBarWidths(code) else { return nil }
        let top = modules(widths[0..<23], startingDark: false) + [true, false]
        let bottom = [true, false] + modules(widths[23...], startingDark: true)
        let middle = (0..<50).map { $0 >= 5 && $0 < 46 && $0 % 2 == 1 }
        return BarcodeBars(rows: [BarcodeBars.Row(modules: top, height: 33),
                                  BarcodeBars.Row(modules: separator(top, finder: 18..<30), height: 1),
                                  BarcodeBars.Row(modules: middle, height: 1),
                                  BarcodeBars.Row(modules: separator(bottom, finder: 16..<32), height: 1),
                                  BarcodeBars.Row(modules: bottom, height: 33)], quietZone: 2)
    }

    /// A row's complement inside four-module margins, with its finder's light
    /// runs alternated so the separator never merges with the finder.
    private static func separator(_ row: [Bool], finder: Range<Int>) -> [Bool] {
        var separator = row.indices.map { $0 >= 4 && $0 < 46 && !row[$0] }
        var latch = true
        for index in finder {
            if row[index] {
                separator[index] = false
                latch = true
            } else {
                separator[index] = latch
                latch.toggle()
            }
        }
        return separator
    }

    /// The widths of `elements` alternating elements spending `modules` in
    /// all, for the `value`th combination, by the ISO/IEC 24724 algorithm.
    static func elementWidths(_ value: Int, modules total: Int, elements: Int, widest: Int, noNarrow: Bool) -> [Int] {
        var value = value, remaining = total, narrowMask = 0
        var widths = Array(repeating: 0, count: elements)
        for bar in 0..<elements - 1 {
            var width = 1
            narrowMask |= 1 << bar
            var subValue = 0
            while true {
                subValue = combinations(remaining - width - 1, elements - bar - 2)
                if !noNarrow, narrowMask == 0, remaining - width - (elements - bar - 1) >= elements - bar - 1 {
                    subValue -= combinations(remaining - width - (elements - bar), elements - bar - 2)
                }
                if elements - bar - 1 > 1 {
                    var less = 0
                    var widestElement = remaining - width - (elements - bar - 2)
                    while widestElement > widest {
                        less += combinations(remaining - width - widestElement - 1, elements - bar - 3)
                        widestElement -= 1
                    }
                    subValue -= less * (elements - 1 - bar)
                } else if remaining - width > widest {
                    subValue -= 1
                }
                value -= subValue
                if value < 0 { break }
                width += 1
                narrowMask &= ~(1 << bar)
            }
            value += subValue
            remaining -= width
            widths[bar] = width
        }
        widths[elements - 1] = remaining
        return widths
    }

    /// n choose r as ISO/IEC 24724's reference computes it, including its
    /// result of 1 when r exceeds n.
    private static func combinations(_ n: Int, _ r: Int) -> Int {
        let (minDenominator, maxDenominator) = n - r > r ? (r, n - r) : (n - r, r)
        var result = 1, divisor = 1
        var value = n
        while value > maxDenominator {
            result *= value
            if divisor <= minDenominator {
                result /= divisor
                divisor += 1
            }
            value -= 1
        }
        while divisor <= minDenominator {
            result /= divisor
            divisor += 1
        }
        return result
    }
}
