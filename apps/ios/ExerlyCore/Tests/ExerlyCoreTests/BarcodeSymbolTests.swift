import Foundation
import Testing
@testable import ExerlyCore

/// The synthetic codes the scanner benchmark draws. Vision reading them back
/// is checked in ExerlyTests' BarcodeBenchmarkTests; these pin their layout.
@Suite struct BarcodeSymbolTests {
    private func pattern(_ bars: BarcodeBars?, row: Int = 0) -> String {
        String(bars!.rows[row].modules.map { $0 ? "#" : "." })
    }

    @Test func eanAndUPCHaveTheirGuardsAndWidths() throws {
        let ean = try #require(BarcodeEncoder.ean13("4006381333931"))
        let modules = pattern(ean)
        #expect(modules.count == 95 && modules.hasPrefix("#.#") && modules.hasSuffix("#.#"))
        #expect(modules.dropFirst(45).prefix(5) == ".#.#.")
        // First digit 4 sets the left half's parity LGLLGG; the second digit, 0, is L.
        #expect(modules.dropFirst(3).prefix(7) == "...##.#")
        #expect(pattern(BarcodeEncoder.upcA("036000291452")) == pattern(BarcodeEncoder.ean13("0036000291452")))
        #expect(pattern(BarcodeEncoder.ean8("96385074")).count == 67)
        let upcE = pattern(BarcodeEncoder.upcE("04252614"))
        #expect(upcE.count == 51 && upcE.hasSuffix(".#.#.#"))
        #expect(BarcodeEncoder.ean13("4006381333932") == nil)
        #expect(BarcodeEncoder.upcE("24252614") == nil)
    }

    @Test func itf14IsFramedWithWideElementsTwoAndAHalfTimesNarrow() throws {
        let itf = try #require(BarcodeEncoder.itf14("10012345678902"))
        #expect(itf.bearer)
        // Start (4 narrow), 7 pairs of 4 wide and 6 narrow elements, stop (wide, narrow, narrow).
        #expect(itf.width == 4 * 2 + 7 * (4 * 5 + 6 * 2) + 5 + 2 * 2)
        #expect(BarcodeEncoder.itf14("10012345678903") == nil)
    }

    @Test func gs1128StartsWithFNC1AndCarriesItsCheckSymbol() throws {
        let code = try #require(BarcodeEncoder.gs1128([("01", "09506000134352"), ("3103", "000512")]))
        // Start C, FNC1, 13 pairs, check, stop: 11 modules each, 13 for the stop.
        #expect(code.width == 11 * 16 + 13)
        let modules = pattern(code)
        #expect(modules.hasPrefix("##.#..###..") && modules.dropFirst(11).hasPrefix("####.#.###.") && modules.hasSuffix("##...###.#.##"))
        #expect(BarcodeEncoder.gs1128([("10", "ABC")]) == nil)
    }

    /// Element widths match the reference encoder (bwip-js) for these GTINs.
    @Test func dataBarMatchesTheReferenceEncoder() {
        let reference: [String: [Int]] = [
            "09506000134352": [1, 1, 5, 1, 1, 1, 5, 1, 1, 1, 1, 3, 9, 1, 1, 2, 1, 1, 1, 2, 1, 5, 2, 2, 2, 2, 1, 2, 3, 1, 2,
                               1, 1, 5, 5, 3, 2, 3, 1, 4, 1, 1, 2, 2, 1, 1],
            "00012345678905": [1, 1, 1, 1, 1, 1, 2, 1, 8, 1, 2, 7, 4, 1, 1, 3, 2, 1, 1, 2, 1, 4, 1, 3, 2, 1, 1, 1, 1, 2, 4,
                               1, 1, 7, 3, 3, 2, 2, 2, 4, 1, 3, 1, 1, 1, 1],
            "10012345678902": [1, 1, 5, 1, 3, 1, 3, 1, 1, 1, 2, 7, 4, 1, 1, 1, 2, 1, 1, 4, 1, 4, 1, 1, 1, 1, 3, 5, 1, 2, 1,
                               1, 1, 7, 5, 1, 2, 2, 2, 1, 1, 1, 1, 6, 1, 1],
        ]
        for (code, widths) in reference {
            #expect(BarcodeEncoder.dataBarWidths(code) == widths, "\(code)")
            #expect(BarcodeEncoder.dataBar(code)?.width == 96)
        }
        #expect(BarcodeEncoder.dataBar("09506000134353") == nil)
    }

    @Test func dataBarStackedMatchesTheReferenceRows() throws {
        let stacked = try #require(BarcodeEncoder.dataBarStacked("09506000134352"))
        #expect(stacked.rows.map(\.height) == [33, 1, 1, 1, 33])
        #expect(pattern(stacked, row: 0) == ".#.....#.#.....#.#.###.........#.##.#.##.#####..#.")
        #expect(pattern(stacked, row: 1) == "....###.#.#####.#.#...#.#.#.#.#.#..#.#..#.........")
        #expect(pattern(stacked, row: 2) == ".....#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#....")
        #expect(pattern(stacked, row: 3) == "....##..#..###.##.#.....#.#.#...##...#....#.##....")
        #expect(pattern(stacked, row: 4) == "#.##..##.##...#..#.#####.....###..###.####.#..##.#")
    }

    /// Each DataBar character's widths enumerate its combinations one to one.
    @Test func dataBarWidthsAreABijection() {
        for (modules, widest, count, noNarrow) in [(12, 8, 161, true), (10, 6, 80, true), (8, 4, 31, true), (8, 5, 34, false),
                                                   (6, 3, 10, false), (5, 2, 4, false), (10, 7, 84, true)] {
            let all = (0..<count).map { BarcodeEncoder.elementWidths($0, modules: modules, elements: 4, widest: widest, noNarrow: noNarrow) }
            #expect(Set(all).count == count && all.allSatisfy { $0.reduce(0, +) == modules && $0.allSatisfy { (1...widest).contains($0) } })
        }
    }
}
