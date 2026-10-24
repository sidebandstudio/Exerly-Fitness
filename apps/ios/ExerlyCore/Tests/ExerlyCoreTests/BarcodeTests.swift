import Foundation
import Testing
@testable import ExerlyCore

/// The digits with their GS1 check digit appended.
private func checked(_ body: String) -> String { body + String(GTIN.checkDigit(of: body)!) }
private func gtin(_ digits: String) -> GTIN { GTIN(digits)! }

@Suite struct GTINTests {
    @Test func checkDigitsMatchPublishedCodes() {
        for code in ["4006381333931", "036000291452", "96385074", "10012345678902", "0012345678905", "9780306406157"] {
            #expect(GTIN.hasValidCheckDigit(code), "\(code)")
        }
        #expect(GTIN.checkDigit(of: "400638133393") == 1)
        #expect(GTIN.checkDigit(of: "03600029145") == 2)
        #expect(GTIN.checkDigit(of: "") == nil)
        #expect(GTIN.checkDigit(of: "12a") == nil)
    }

    /// Mod 10 catches every single wrong digit, so a misread of one digit
    /// never becomes another product.
    @Test func everySingleDigitMisreadIsRejected() {
        var generator = SystemRandomNumberGenerator()
        for length in [8, 12, 13, 14] {
            for _ in 0..<200 {
                let body = String((0..<length - 1).map { _ in Character(String(Int.random(in: 0...9, using: &generator))) })
                let code = Array(checked(body))
                #expect(GTIN(String(code)) != nil)
                for position in code.indices {
                    for digit in "0123456789" where digit != code[position] {
                        var misread = code
                        misread[position] = digit
                        #expect(GTIN(String(misread)) == nil, "\(String(misread)) passed for \(String(code))")
                    }
                }
            }
        }
    }

    @Test func refusesWhatIsNotAGTIN() {
        for text in ["", "1234567", "123456789012345", "03600029145a", " 036000291452", "036000291453"] {
            #expect(GTIN(text) == nil, "\(text)")
        }
    }

    /// One product, however its code is written, has one key.
    @Test func everyFormOfAProductSharesOneKey() throws {
        let forms = ["036000291452", "0036000291452", "00036000291452", "36000291452"]
        #expect(Set(forms.compactMap { GTIN($0) }.map(\.key)) == ["00036000291452"])
        let upcE = BarcodePayload.read("04252614", as: .upcE)
        #expect(try upcE.get().gtin == gtin("042100005264"))
        #expect(try upcE.get().gtin == gtin("0042100005264"))
        #expect(gtin("96385074").key == "00000096385074")
    }

    /// The phone's key and Open Food Facts code match the server's
    /// `normalizeBarcode` (apps/api/lib/barcodes.js) for the same codes.
    @Test func keysMatchTheServer() throws {
        let server: [(String, BarcodeSymbology, String, String)] = [
            ("036000291452", .upcA, "00036000291452", "0036000291452"),
            ("0036000291452", .ean13, "00036000291452", "0036000291452"),
            ("00036000291452", .itf14, "00036000291452", "0036000291452"),
            ("04252614", .upcE, "00042100005264", "0042100005264"),
            ("01234565", .upcE, "00012345000065", "0012345000065"),
            ("96385074", .ean8, "00000096385074", "96385074"),
            ("4006381333931", .ean13, "04006381333931", "4006381333931"),
            ("10012345678902", .itf14, "10012345678902", "10012345678902"),
            ("0012345678905", .ean13, "00012345678905", "0012345678905"),
        ]
        for (code, symbology, key, openFoodFacts) in server {
            let read = try BarcodePayload.read(code, as: symbology).get()
            #expect(read.gtin.key == key, "\(code)")
            #expect(read.gtin.openFoodFacts == openFoodFacts, "\(code)")
        }
        // The server refuses these too.
        #expect(BarcodePayload.read("5000000000017", as: .ean13) == .failure(.checkDigit))
        #expect(BarcodePayload.read("0041000000016", as: .ean13) == .failure(.checkDigit))
    }

    @Test func showsTheFormPrintedUnderTheBars() {
        #expect(gtin("00036000291452").display == "036000291452")
        #expect(gtin("4006381333931").display == "4006381333931")
        #expect(gtin("96385074").display == "96385074")
        #expect(gtin("10012345678902").display == "10012345678902")
        #expect(gtin("036000291452").gtin13 == "0036000291452")
        #expect(gtin("4006381333931").upcA == nil)
        #expect(gtin("10012345678902").gtin13 == nil)
    }

    @Test func codableAsItsKey() throws {
        let data = try JSONEncoder().encode([gtin("036000291452")])
        #expect(String(decoding: data, as: UTF8.self) == "[\"00036000291452\"]")
        #expect(try JSONDecoder().decode([GTIN].self, from: data) == [gtin("036000291452")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([GTIN].self, from: Data("[\"036000291452\"]".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([GTIN].self, from: Data("[\"00036000291453\"]".utf8)) }
    }
}

@Suite struct UPCETests {
    @Test func expandsPublishedExamples() {
        #expect(GTIN.expandUPCE("04252614") == "042100005264")
        #expect(GTIN.expandUPCE("01234565") == "012345000065")
        // Each final digit's rule.
        #expect(GTIN.expandUPCE("0123450")?.prefix(11) == "01200000345")
        #expect(GTIN.expandUPCE("0123451")?.prefix(11) == "01210000345")
        #expect(GTIN.expandUPCE("0123452")?.prefix(11) == "01220000345")
        #expect(GTIN.expandUPCE("0123453")?.prefix(11) == "01230000045")
        #expect(GTIN.expandUPCE("0123454")?.prefix(11) == "01234000005")
        #expect(GTIN.expandUPCE("0123459")?.prefix(11) == "01234500009")
    }

    @Test func sixAndSevenDigitsComputeTheCheckDigit() {
        #expect(GTIN.expandUPCE("425261") == "042100005264")
        #expect(GTIN.expandUPCE("0425261") == "042100005264")
        #expect(GTIN.expandUPCE("1425261") == checked("14210000526"))
    }

    @Test func refusesAWrongCheckDigitOrNumberSystem() {
        #expect(GTIN.expandUPCE("04252615") == nil)
        #expect(GTIN.expandUPCE("24252614") == nil)
        #expect(GTIN.expandUPCE("12345") == nil)
        #expect(GTIN.expandUPCE("042526145") == nil)
        #expect(GTIN.expandUPCE("0425a614") == nil)
    }

    /// Every UPC-E the rules can tell apart, in both number systems: the
    /// rules turn on the last four data digits and copy the first two, so all
    /// 10,000 endings are tried after several leading pairs. Each expands to a
    /// valid UPC-A that compresses back to a UPC-E with the same expansion.
    @Test func everyUPCERoundTrips() {
        var failures: [String] = []
        for system in ["0", "1"] {
            for lead in ["00", "09", "42", "90", "99"] {
                for value in 0..<10_000 {
                    let seven = system + lead + String(format: "%04ld", value)
                    guard let upcA = GTIN.expandUPCE(seven), GTIN.hasValidCheckDigit(upcA),
                          let back = GTIN.compressUPCA(upcA), GTIN.expandUPCE(back) == upcA else { failures.append(seven); continue }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test func onlyZeroSuppressibleUPCAsCompress() {
        #expect(GTIN.compressUPCA("042100005264") == "04252614")
        #expect(GTIN.compressUPCA("036000291452") == nil)
        #expect(GTIN.compressUPCA("236000291459") == nil)
    }
}

@Suite struct GTINKindTests {
    @Test func productsAreLookedUp() {
        for code in ["036000291452", "4006381333931", "96385074", "76543210", "10012345678902", "0012345678905"] {
            #expect(gtin(code).kind == .product, "\(code)")
        }
    }

    /// In-store labels for weighed or priced items carry the store's item
    /// number and an embedded price or weight, not a product identity.
    @Test func variableMeasureLabelsAreRecognised() {
        let upc = gtin(checked("20123400599"))
        #expect(upc.kind == .variableMeasure(itemReference: "01234", embeddedValue: "00599"))
        let ean = gtin(checked("211234500512"))
        #expect(ean.kind == .variableMeasure(itemReference: "12345", embeddedValue: "00512"))
        for first in 20...29 {
            #expect(!gtin(checked("\(first)1234500512")).isProduct)
        }
        let leadingZero = gtin(checked("028765400250"))
        #expect(leadingZero.kind == .variableMeasure(itemReference: "87654", embeddedValue: "00250"))
        // Indicator 9 marks a variable-measure trade item.
        if case .variableMeasure = gtin(checked("9950600013435")).kind {} else { Issue.record("Indicator 9 is variable measure") }
    }

    /// GS1 reserves EAN-8s starting 0 or 2 for numbers a company issues for
    /// itself, so two retailers can use one for different foods.
    @Test func restrictedEAN8sAreAStoresOwnNumbers() {
        #expect(gtin("20123451").kind == .storeInternal)
        #expect(gtin(checked("0123456")).kind == .storeInternal)
        #expect(gtin(checked("2987654")).kind == .storeInternal)
        for first in ["1", "3", "4", "5", "6", "7", "8", "9"] {
            #expect(gtin(checked(first + "123456")).kind == .product, "\(first)")
        }
    }

    @Test func storeCouponAndPublicationCodesAreNotProducts() {
        #expect(gtin(checked("41234567890")).kind == .storeInternal)
        #expect(gtin(checked("51234567890")).kind == .coupon)
        #expect(gtin(checked("981123456789")).kind == .coupon)
        #expect(gtin(checked("991123456789")).kind == .coupon)
        #expect(gtin(checked("978030640615")).kind == .publication)
        #expect(gtin(checked("977123456789")).kind == .publication)
        #expect(gtin(checked("976123456789")).kind == .product)
        #expect(gtin(checked("191234567890")).kind == .product)
        #expect(gtin(checked("301234567890")).kind == .product)
    }
}

@Suite struct BarcodePayloadTests {
    @Test func linearRetailCodesNeedTheirLength() throws {
        #expect(try BarcodePayload.read("0036000291452", as: .ean13).get().gtin == gtin("036000291452"))
        #expect(try BarcodePayload.read("036000291452", as: .upcA).get().gtin == gtin("036000291452"))
        #expect(try BarcodePayload.read("96385074", as: .ean8).get().gtin.key == "00000096385074")
        #expect(try BarcodePayload.read("10012345678902", as: .itf14).get().gtin.key == "10012345678902")
        #expect(BarcodePayload.read("036000291452", as: .ean13) == .failure(.length))
        #expect(BarcodePayload.read("0036000291453", as: .ean13) == .failure(.checkDigit))
        #expect(BarcodePayload.read("96385075", as: .ean8) == .failure(.checkDigit))
        #expect(BarcodePayload.read("0425261", as: .upcE).map(\.gtin) == .success(gtin("042100005264")))
        #expect(BarcodePayload.read("04252615", as: .upcE) == .failure(.checkDigit))
        #expect(BarcodePayload.read("0425", as: .upcE) == .failure(.length))
    }

    @Test func dataBarIsReadWithOrWithoutItsIdentifier() throws {
        let expected = gtin("09506000134352")
        for payload in ["0109506000134352", "(01)09506000134352", "]e00109506000134352", "09506000134352", "0950600013435"] {
            #expect(try BarcodePayload.read(payload, as: .dataBar).get().gtin == expected, "\(payload)")
            #expect(try BarcodePayload.read(payload, as: .dataBarLimited).get().gtin == expected, "\(payload)")
        }
        #expect(BarcodePayload.read("0109506000134353", as: .dataBar) == .failure(.checkDigit))
    }

    @Test func gs1ElementStringsCarryTheGTINAndNetWeight() throws {
        let weighed = checked("9950600013435")
        let raw = "]C101\(weighed)3103000512\u{1D}10LOT42\u{1D}17271231"
        let read = try BarcodePayload.read(raw, as: .code128).get()
        #expect(read.gtin.key == weighed)
        #expect(read.netWeightGrams == 512)
        let parenthesized = try BarcodePayload.read("(01)\(weighed)(3202)000150(10)LOT", as: .dataBarExpanded).get()
        #expect(abs((parenthesized.netWeightGrams ?? 0) - 1.5 * 453.59237) < 0.001)
        let fnc1First = try BarcodePayload.read("\u{1D}0109506000134352\u{1D}21SERIAL", as: .dataMatrix).get()
        #expect(fnc1First.gtin == gtin("09506000134352"))
        #expect(BarcodePayload.read("0109506000134353", as: .code128) == .failure(.checkDigit))
    }

    @Test func plainCode128DigitsAndOtherText() throws {
        #expect(try BarcodePayload.read("0012345678905", as: .code128).get().gtin == gtin("0012345678905"))
        #expect(BarcodePayload.read("ABC-123", as: .code128) == .failure(.noGTIN))
        #expect(BarcodePayload.read("0012345678906", as: .code128) == .failure(.checkDigit))
        #expect(BarcodePayload.read("123456", as: .dataMatrix) == .failure(.noGTIN))
    }

    @Test func gs1DigitalLinksCarryTheirGTIN() throws {
        let links = [
            "https://id.gs1.org/01/09506000134352/10/ABC123?17=271231",
            "https://brand.example/01/9506000134352",
            "http://example.test/gtin/09506000134352",
            "https://example.test/products/01/09506000134352",
        ]
        for link in links {
            #expect(try BarcodePayload.read(link, as: .qr).get().gtin == gtin("09506000134352"), "\(link)")
        }
        #expect(BarcodePayload.read("https://id.gs1.org/01/09506000134353", as: .qr) == .failure(.checkDigit))
        #expect(BarcodePayload.read("https://example.test/menu", as: .qr) == .failure(.noGTIN))
        #expect(BarcodePayload.read("Hello", as: .microQR) == .failure(.noGTIN))
        #expect(try BarcodePayload.read("(01)09506000134352", as: .qr).get().gtin == gtin("09506000134352"))
    }

    @Test func typedDigitsMayDropLeadingZerosAndTryBothEightDigitFormats() throws {
        #expect(GTIN.candidates(typed: "36000291452") == [gtin("036000291452")])
        #expect(GTIN.candidates(typed: "0 36000 29145 2") == [gtin("036000291452")])
        #expect(GTIN.candidates(typed: "96385074") == [gtin("96385074")])
        #expect(GTIN.candidates(typed: "04252614") == [gtin("042100005264")])
        #expect(GTIN.candidates(typed: "425261") == [gtin("042100005264")])
        #expect(GTIN.candidates(typed: "036000291453").isEmpty)
        #expect(GTIN.candidates(typed: "12345").isEmpty)
        // An eight-digit code valid both ways is tried both ways, a product first:
        // starting 0, the EAN-8 would be a store's own number.
        let both = try #require((0..<10_000_000).lazy.map { "0" + String(format: "%07ld", $0) }
            .first { code in GTIN(code) != nil && GTIN.expandUPCE(code).flatMap { GTIN($0) }.map { $0 != GTIN(code) } == true })
        #expect(GTIN.candidates(typed: both) == [gtin(GTIN.expandUPCE(both)!), gtin(both)])
        #expect(try BarcodePayload.read(both, as: .typed).get().gtin == gtin(GTIN.expandUPCE(both)!))
        let ean8 = try #require((10_000_000..<20_000_000).lazy.map { String($0) }.first { GTIN($0) != nil && GTIN.expandUPCE($0) != nil })
        #expect(GTIN.candidates(typed: ean8).first == gtin(ean8))
    }
}

@Suite struct BarcodeLegibilityTests {
    /// The benchmark's misreads came from symbols about two pixels a module wide.
    @Test func shortCodesNeedTwoAndAHalfPixelsAModule() {
        #expect(!BarcodeLegibility.isLegible(.ean8, width: 144))
        #expect(BarcodeLegibility.isLegible(.ean8, width: 168))
        #expect(!BarcodeLegibility.isLegible(.upcE, width: 120))
        #expect(BarcodeLegibility.isLegible(.upcE, width: 128))
        for symbology in [BarcodeSymbology.ean13, .upcA, .itf14, .code128, .dataBar, .qr, .dataMatrix, .typed] {
            #expect(BarcodeLegibility.isLegible(symbology, width: 10))
        }
    }
}

@Suite struct BarcodeConsensusTests {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let oat = ScannedCode(gtin: gtin("0012345678905"), symbology: .ean13)
    let other = ScannedCode(gtin: gtin("036000291452"), symbology: .upcA)

    @Test func oneReadIsNeverEnough() {
        var consensus = BarcodeConsensus()
        let read1 = consensus.observe([oat], at: start)
        #expect(read1.isEmpty)
        let read2 = consensus.observe([oat], at: start + 0.033)
        #expect(read2 == [oat])
    }

    @Test func readsMustAgreeWithinTheWindow() {
        var consensus = BarcodeConsensus()
        let read3 = consensus.observe([oat], at: start)
        #expect(read3.isEmpty)
        let read4 = consensus.observe([oat], at: start + 1.3)
        #expect(read4.isEmpty)
        let read5 = consensus.observe([oat], at: start + 1.4)
        #expect(read5 == [oat])
    }

    @Test func disagreeingReadsDoNotCount() {
        var consensus = BarcodeConsensus()
        let read6 = consensus.observe([oat], at: start)
        #expect(read6.isEmpty)
        let read7 = consensus.observe([other], at: start + 0.03)
        #expect(read7.isEmpty)
        let read8 = consensus.observe([oat, oat], at: start + 0.06)
        #expect(read8 == [oat])
        let read9 = consensus.observe([other], at: start + 0.09)
        #expect(read9 == [other])
    }

    @Test func oneFrameCountsOnce() {
        var consensus = BarcodeConsensus()
        let read10 = consensus.observe([oat, oat, oat], at: start)
        #expect(read10.isEmpty)
    }

    /// A pack held in view is added once; shown again after leaving the
    /// frame, it's added again.
    /// The portion sheet pauses frames with the pack still in view: back from
    /// it, the pack isn't added again until it has left the frame.
    @Test func aPauseKeepsAcceptedCodesHeld() {
        var consensus = BarcodeConsensus()
        let first = consensus.observe([oat], at: start) + consensus.observe([oat], at: start + 0.033)
        #expect(first == [oat])
        consensus.pause()
        let back = start + 20
        var accepted: [ScannedCode] = []
        for frame in 0..<60 { accepted += consensus.observe([oat], at: back + Double(frame) / 30) }
        #expect(accepted.isEmpty, "Still in view after the pause")
        // Out of view for over a second, then shown again: one more pack.
        let gone = back + 2 + 1.1
        for frame in 0..<35 { accepted += consensus.observe([], at: back + 2 + Double(frame) / 30) }
        accepted += consensus.observe([oat], at: gone) + consensus.observe([oat], at: gone + 0.033)
        #expect(accepted == [oat])
        // Unseen when frames resume, it still has to be seen gone a second first.
        consensus.pause()
        let later = gone + 30
        accepted = consensus.observe([], at: later) + consensus.observe([oat], at: later + 0.5) + consensus.observe([oat], at: later + 0.53)
        #expect(accepted.isEmpty)
    }

    @Test func acceptedCodesAreHeldWhileInView() {
        var consensus = BarcodeConsensus()
        var accepted = 0
        for frame in 0..<90 { accepted += consensus.observe([oat], at: start + Double(frame) / 30).count }
        #expect(accepted == 1)
        let back = start + 3 + 1.1
        let read11 = consensus.observe([oat], at: back)
        #expect(read11.isEmpty)
        let read12 = consensus.observe([oat], at: back + 0.03)
        #expect(read12 == [oat])
        consensus.reset()
        let read13 = consensus.observe([oat], at: back + 0.06)
        #expect(read13.isEmpty)
    }

    /// A misread that passes its check digit, such as two swapped digits,
    /// appears in a frame or two among good reads: it's never accepted
    /// unless it repeats.
    @Test func isolatedMisreadsAreNeverAccepted() {
        var consensus = BarcodeConsensus()
        var generator = SystemRandomNumberGenerator()
        var accepted: [ScannedCode] = []
        for frame in 0..<3000 {
            let misread = ScannedCode(gtin: gtin(checked(String(format: "%012ld", Int.random(in: 0..<999_999_999_999, using: &generator)))),
                                      symbology: .ean13)
            // A different misread every 2 s, the window's length apart.
            let codes = frame % 60 == 0 ? [misread] : []
            accepted += consensus.observe(codes, at: start + Double(frame) / 30)
        }
        #expect(accepted.isEmpty)
    }
}

@Suite struct ScannerCameraTests {
    /// Apple's barcode sample: a 20 mm code filling the 1080 × 1920 frame's
    /// width at a 200 mm closest focus and 60° field of view needs 3.25×.
    @Test func zoomBringsSmallCodesWithinFocus() {
        let zoom = ScannerOptics.zoomFactor(minimumFocusDistance: 200, fieldOfView: 60, minimumCodeSize: 20, previewFill: 1080.0 / 1920)
        #expect(abs(zoom - 200 / ((20 / 0.5625) / tan(30 * Double.pi / 180))) < 1e-9)
        #expect(abs(zoom - 3.248) < 0.001)
        #expect(ScannerOptics.zoomFactor(minimumFocusDistance: 50, fieldOfView: 60, previewFill: 0.5625) == 1)
        #expect(ScannerOptics.zoomFactor(minimumFocusDistance: 600, fieldOfView: 60, previewFill: 0.5625) == 4)
        #expect(ScannerOptics.zoomFactor(minimumFocusDistance: 0, fieldOfView: 60, previewFill: 0.5625) == 1)
        #expect(ScannerOptics.zoomFactor(minimumFocusDistance: 200, fieldOfView: 0, previewFill: 0.5625) == 1)
    }

    /// A window across the middle of a portrait viewfinder is a band
    /// along the sensor's long side; Vision gets it upright.
    @Test func theViewfinderWindowTurnsWithThePortraitFrame() throws {
        // Sensor: 30% of the long side (portrait height), 80% of the short side (portrait width).
        let sensor = CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.8)
        let region = try #require(ScannerOptics.visionRegion(sensor: sensor, padding: 0))
        #expect(abs(region.width - 0.8) < 1e-9 && abs(region.height - 0.3) < 1e-9)
        #expect(abs(region.midX - 0.5) < 1e-9 && abs(region.midY - 0.5) < 1e-9)
        // Off centre: the top of the portrait frame is the sensor's left edge.
        let top = try #require(ScannerOptics.visionRegion(sensor: CGRect(x: 0, y: 0.1, width: 0.2, height: 0.8), padding: 0))
        #expect(abs(top.maxY - 1) < 1e-9 && abs(top.minY - 0.8) < 1e-9)
        let padded = try #require(ScannerOptics.visionRegion(sensor: CGRect(x: 0, y: 0, width: 0.2, height: 1)))
        #expect(padded.minX == 0 && padded.maxX == 1 && abs(padded.minY - 0.72) < 1e-9)
        #expect(ScannerOptics.visionRegion(sensor: .zero) == nil)
    }

    @Test func theLightIsSuggestedOnlyAfterSustainedDark() {
        var advisor = LowLightAdvisor()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let read14 = advisor.observe(brightness: 2, at: start, torchOn: false)
        #expect(!read14)
        let read15 = advisor.observe(brightness: -2, at: start + 1, torchOn: false)
        #expect(!read15)
        let read16 = advisor.observe(brightness: -2, at: start + 2, torchOn: false)
        #expect(!read16)
        let read17 = advisor.observe(brightness: -2, at: start + 2.3, torchOn: false)
        #expect(read17)
        // A flicker of light doesn't withdraw it.
        let read18 = advisor.observe(brightness: 1, at: start + 2.5, torchOn: false)
        #expect(read18)
        let read19 = advisor.observe(brightness: -2, at: start + 2.6, torchOn: false)
        #expect(read19)
        let read20 = advisor.observe(brightness: -2, at: start + 3, torchOn: true)
        #expect(!read20)
        let read21 = advisor.observe(brightness: -2, at: start + 3.5, torchOn: false)
        #expect(!read21)
    }

    @Test func brightnessWithdrawsTheSuggestion() {
        var advisor = LowLightAdvisor()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        advisor.observe(brightness: -3, at: start, torchOn: false)
        let read22 = advisor.observe(brightness: -3, at: start + 1.5, torchOn: false)
        #expect(read22)
        let read23 = advisor.observe(brightness: 1, at: start + 2, torchOn: false)
        #expect(read23)
        let read24 = advisor.observe(brightness: 1, at: start + 3.3, torchOn: false)
        #expect(!read24)
    }
}

@MainActor @Suite struct BarcodeLibraryTests {
    let day = LocalDate(year: 2026, month: 10, day: 20)!
    var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let oat = gtin("0012345678905")

    func food(_ name: String = "Synthetic oat bar") -> Food {
        Food(id: "off:0012345678905", name: name, source: .openFoodFacts, per100g: NutrientAmounts([.energy: 400]))
    }

    final class Counter { var calls: [GTIN] = [] }

    func fetch(_ result: BarcodeLibrary.Fetched, counter: Counter) -> BarcodeLibrary.Fetch {
        { gtin in counter.calls.append(gtin); return result }
    }

    @Test func aResolvedCodeIsCachedAndFoundByAnyFormOffline() async {
        let persistence = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: persistence, now: { clock })
        let counter = Counter()
        let first = await library.resolve(gtin("012345678905"), meal: "Lunch", date: day,
                                          fetch: fetch(.found(food(), attribution: "Open Food Facts"), counter: counter))
        guard case .found(let product, cached: false) = first else { Issue.record("\(first)"); return }
        #expect(product.food.name == "Synthetic oat bar")
        // Offline, scanned as EAN-13 this time, from a fresh launch.
        let reopened = BarcodeLibrary(persistence: persistence, now: { clock })
        let again = await reopened.resolve(gtin("0012345678905"), meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter))
        #expect(again == .found(product, cached: true))
        #expect(counter.calls == [oat])
        #expect(reopened.history.map(\.gtin) == [oat])
    }

    @Test func eachAccountHasItsOwnLibrary() async {
        let mine = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let theirs = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        _ = await mine.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        #expect(theirs.product(oat) == nil && theirs.history.isEmpty)
        #expect(await theirs.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter)) == .queued)
    }

    @Test func anOfflineScanWaitsAndResolvesLater() async {
        let persistence = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: persistence, now: { clock })
        let counter = Counter()
        #expect(await library.resolve(oat, meal: "Dinner", date: day, fetch: fetch(.unavailable, counter: counter)) == .queued)
        #expect(library.waiting.map(\.gtin) == [oat])
        #expect(library.waiting.first?.meal == "Dinner" && library.waiting.first?.date == day)
        // Still offline: nothing changes, nothing is lost, across a relaunch.
        #expect(await library.resolveWaiting(fetch: fetch(.unavailable, counter: counter)).isEmpty)
        let reopened = BarcodeLibrary(persistence: persistence, now: { clock })
        #expect(reopened.waiting.map(\.gtin) == [oat])
        let resolved = await reopened.resolveWaiting(fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        #expect(resolved.map(\.gtin) == [oat] && resolved.first?.state == .ready)
        #expect(reopened.waiting.isEmpty && reopened.ready.map(\.gtin) == [oat])
        #expect(reopened.product(oat)?.food.name == "Synthetic oat bar")
        reopened.acknowledge(resolved[0].id)
        #expect(reopened.ready.isEmpty)
        #expect(BarcodeLibrary(persistence: persistence, now: { clock }).ready.isEmpty)
    }

    @Test func waitingScansResolveInOrderAndStopWhenOfflineAgain() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        let codes = [oat, gtin("036000291452"), gtin("96385074")]
        for code in codes { _ = await library.resolve(code, meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter)) }
        #expect(library.waiting.map(\.gtin) == codes)
        var answers: [BarcodeLibrary.Fetched] = [.found(food(), attribution: "OFF"), .missing, .unavailable]
        let resolved = await library.resolveWaiting { gtin in counter.calls.append(gtin); return answers.removeFirst() }
        #expect(resolved.map(\.state) == [.ready, .missing])
        #expect(library.waiting.map(\.gtin) == [gtin("96385074")])
    }

    @Test func aMissIsRecordedAndRetriedNextTime() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        #expect(await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.missing, counter: counter)) == .missing)
        #expect(library.history.first?.state == .missing)
        let found = await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        if case .found(_, cached: false) = found {} else { Issue.record("\(found)") }
        #expect(counter.calls.count == 2 && library.history.count == 1)
    }

    @Test func aFoodEnteredForAMissedCodeIsFoundNextTime() async {
        let persistence = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: persistence, now: { clock })
        let counter = Counter()
        #expect(await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.missing, counter: counter)) == .missing)
        library.remember(food("Synthetic oat bar, typed in"), for: oat, attribution: "Your food")
        #expect(library.history.map(\.state) == [.found])
        let again = await BarcodeLibrary(persistence: persistence, now: { clock })
            .resolve(gtin("012345678905"), meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter))
        guard case .found(let product, cached: true) = again else { Issue.record("\(again)"); return }
        #expect(product.food.name == "Synthetic oat bar, typed in" && product.attribution == "Your food")
        #expect(counter.calls.count == 1)
    }

    @Test func inStoreLabelsAreNeverLookedUp() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        let label = gtin(checked("20123400599"))
        #expect(await library.resolve(label, meal: "Lunch", date: day, fetch: fetch(.missing, counter: counter)) == .notProduct(label.kind))
        #expect(counter.calls.isEmpty && library.history.isEmpty)
    }

    /// Scanned offline for Lunch, then for Dinner: each keeps its own meal,
    /// day and time, across a relaunch, and each logs where it was meant to.
    @Test mutating func everyOfflineScanKeepsItsOwnLoggingIntent() async {
        var now = clock
        let persistence = InMemoryTrainingPersistence()
        let library = BarcodeLibrary(persistence: persistence, now: { now })
        let counter = Counter()
        let dinnerDay = LocalDate(year: 2026, month: 10, day: 21)!
        _ = await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter))
        now += 6 * 3600
        _ = await library.resolve(gtin("012345678905"), meal: "Dinner", date: dinnerDay, fetch: fetch(.unavailable, counter: counter))
        let reopened = BarcodeLibrary(persistence: persistence, now: { now })
        #expect(reopened.waiting.map(\.meal) == ["Lunch", "Dinner"])
        #expect(reopened.waiting.map(\.date) == [day, dinnerDay])
        #expect(reopened.waiting.map(\.scannedAt) == [clock, clock + 6 * 3600])
        #expect(Set(reopened.waiting.map(\.id)).count == 2 && reopened.history.count == 1)
        let resolved = await reopened.resolveWaiting(fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        #expect(resolved.map(\.meal) == ["Lunch", "Dinner"] && counter.calls.count == 3, "One lookup for both")
        reopened.acknowledge(resolved[0].id)
        #expect(reopened.ready.map(\.meal) == ["Dinner"])
    }

    /// Scanning a code again, online, doesn't clear a scan still to be logged.
    @Test func rescanningKeepsAnOfflineScanReady() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        _ = await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter))
        await library.resolveWaiting(fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        _ = await library.resolve(oat, meal: "Snacks", date: day, fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        #expect(library.ready.map(\.meal) == ["Lunch"])
        // A second offline scan, then the code resolves online: both are ready.
        let other = gtin("036000291452")
        _ = await library.resolve(other, meal: "Dinner", date: day, fetch: fetch(.unavailable, counter: counter))
        _ = await library.resolve(other, meal: "Dinner", date: day, fetch: fetch(.found(food("Synthetic tea"), attribution: "OFF"), counter: counter))
        #expect(library.ready.map(\.meal) == ["Lunch", "Dinner"] && library.waiting.isEmpty)
    }

    /// A store's own EAN-8 is never looked up, nor answered from a product
    /// another store's code cached; the person's own food for it still is.
    @Test func aStoresOwnCodeAnswersOnlyWithTheirOwnFood() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { clock })
        let counter = Counter()
        let store = gtin("20123451")
        #expect(await library.resolve(store, meal: "Lunch", date: day, fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
                == .notProduct(.storeInternal))
        #expect(counter.calls.isEmpty)
        library.remember(food("Synthetic deli salad"), for: store, attribution: "Your food")
        let mine = await library.resolve(store, meal: "Lunch", date: day, fetch: fetch(.missing, counter: counter))
        guard case .found(let product, cached: true) = mine else { Issue.record("\(mine)"); return }
        #expect(product.food.name == "Synthetic deli salad" && product.own && counter.calls.isEmpty)
        #expect(!library.isStale(product))
    }

    @Test mutating func historyIsLatestFirstBoundedAndKeepsWaitingScans() async {
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { [clock] in clock })
        let counter = Counter()
        _ = await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.unavailable, counter: counter))
        for index in 0..<(BarcodeLibrary.historyLimit + 5) {
            let code = gtin(checked(String(format: "4%011ld", index + 1)))
            _ = await library.resolve(code, meal: "Lunch", date: day, fetch: fetch(.missing, counter: counter))
        }
        #expect(library.history.count == BarcodeLibrary.historyLimit)
        #expect(library.history.first?.gtin == gtin(checked(String(format: "4%011ld", BarcodeLibrary.historyLimit + 5))))
        // The code fell out of the history; its offline scan didn't.
        #expect(!library.history.contains { $0.gtin == oat } && library.waiting.map(\.gtin) == [oat])
        library.remove(oat)
        #expect(library.waiting.map(\.gtin) == [oat])
    }

    @Test func refreshKeepsTheCachedProductWhenOffline() async {
        var now = clock
        let library = BarcodeLibrary(persistence: InMemoryTrainingPersistence(), now: { now })
        let counter = Counter()
        _ = await library.resolve(oat, meal: "Lunch", date: day, fetch: fetch(.found(food(), attribution: "OFF"), counter: counter))
        let product = library.product(oat)!
        #expect(!library.isStale(product))
        now += BarcodeLibrary.refreshAge + 1
        #expect(library.isStale(product))
        await library.refresh(oat, fetch: fetch(.unavailable, counter: counter))
        #expect(library.product(oat) == product)
        await library.refresh(oat, fetch: fetch(.found(food("Synthetic oat bar, new recipe"), attribution: "OFF"), counter: counter))
        #expect(library.product(oat)?.food.name == "Synthetic oat bar, new recipe")
        #expect(!library.isStale(library.product(oat)!))
    }
}

@Suite struct ScanTrayAmountTests {
    let bar = Serving("1 bar", grams: 40)
    var food: Food { Food(id: "off:0012345678905", name: "Synthetic oat bar", source: .openFoodFacts,
                          per100g: NutrientAmounts([.energy: 400]), servings: [bar]) }

    @Test func aSecondPackAddsOneMoreServing() throws {
        let one = try NutritionStore.preview(food, serving: bar, quantity: 1)
        let two = try ScanTrayAmount.adding(one, to: one, of: food)
        #expect(two.quantity == 2 && two.serving == bar && two.grams == 80 && two.nutrients.energy == 320)
        let halfMore = try ScanTrayAmount.adding(try NutritionStore.preview(food, serving: bar, quantity: 0.5), to: two, of: food)
        #expect(halfMore.quantity == 2.5)
    }

    @Test func differentUnitsAddByWeight() throws {
        let grams = try NutritionStore.preview(food, grams: 30)
        let serving = try NutritionStore.preview(food, serving: bar, quantity: 1)
        let total = try ScanTrayAmount.adding(serving, to: grams, of: food)
        #expect(total.grams == 70 && total.serving == nil && total.nutrients.energy == 280)
    }

    @Test func stepsByOneUsualPortionAndNeverToNothing() throws {
        let one = try NutritionStore.preview(food, serving: bar, quantity: 1)
        #expect(ScanTrayAmount.stepping(one, by: one, of: food, more: true)?.quantity == 2)
        #expect(ScanTrayAmount.stepping(one, by: one, of: food, more: false) == nil)
        let half = try NutritionStore.preview(food, serving: bar, quantity: 1.5)
        #expect(ScanTrayAmount.stepping(half, by: one, of: food, more: false)?.grams == 20)
        // A drink usually logged as 100 ml steps by 100 ml, not 1 ml.
        let ml = Serving("ml", grams: 1)
        let drink = try NutritionStore.preview(food, serving: ml, quantity: 100)
        let two = try #require(ScanTrayAmount.stepping(drink, by: drink, of: food, more: true))
        #expect(two.quantity == 200 && two.grams == 200)
        #expect(ScanTrayAmount.stepping(two, by: drink, of: food, more: false)?.quantity == 100)
        #expect(ScanTrayAmount.stepping(drink, by: drink, of: food, more: false) == nil)
        let grams = try NutritionStore.preview(food, grams: 50)
        #expect(ScanTrayAmount.stepping(grams, by: grams, of: food, more: true)?.grams == 100)
        #expect(ScanTrayAmount.stepping(grams, by: grams, of: food, more: false) == nil)
    }
}

@Suite struct FoodDataCreditTests {
    @Test func openFoodFactsIsCreditedInOneShortLineWithItsLink() {
        let credit = FoodDataCredit.short("Data from Open Food Facts (https://world.openfoodfacts.org), available under the Open Database License.")
        #expect(credit.label == "Open Food Facts · ODbL" && credit.url?.host == "world.openfoodfacts.org")
        #expect(FoodDataCredit.short("Includes USDA FoodData Central data (public domain).").label == "USDA FoodData Central")
        let other = FoodDataCredit.short("Synthetic source, see https://example.test/terms, used with permission")
        #expect(other.label.hasPrefix("Synthetic source") && other.url?.host == "example.test")
        #expect(FoodDataCredit.short("Your food").url == nil)
    }
}
