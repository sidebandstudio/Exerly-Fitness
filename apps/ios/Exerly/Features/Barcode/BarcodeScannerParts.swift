import ExerlyCore
import SwiftUI

// The pieces of Scan barcode: the viewfinder, what a scan came to, the
// plate being built, and past scans to log again.

/// A code as it's printed under the bars.
enum BarcodeText {
    static func printed(_ gtin: GTIN) -> String {
        let digits = Array(gtin.display)
        func group(_ ranges: [Range<Int>]) -> String { ranges.map { String(digits[$0]) }.joined(separator: " ") }
        switch digits.count {
        case 12: return group([0..<1, 1..<6, 6..<11, 11..<12])
        case 13: return group([0..<1, 1..<7, 7..<13])
        case 8: return group([0..<4, 4..<8])
        default: return gtin.display
        }
    }

    /// Digit by digit, so VoiceOver doesn't read it as one huge number.
    static func spoken(_ gtin: GTIN) -> String { gtin.display.map(String.init).joined(separator: " ") }
}

// MARK: - Viewfinder

struct BarcodeViewfinder: View {
    @ObservedObject var camera: BarcodeCamera
    let feedImage: CGImage?
    let feedPrimed: Bool
    let usesCamera: Bool
    let usesFeed: Bool
    let cameraDenied: Bool
    let status: String
    let statusIcon: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if usesCamera || usesFeed {
            GeometryReader { geometry in
                let window = Self.window(in: geometry.size)
                ZStack {
                    Color.black
                    if usesCamera {
                        CameraPreview(camera: camera, viewfinder: window)
                    } else {
                        simulated(window: window)
                    }
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRoundedRect(in: window, cornerSize: CGSize(width: 14, height: 14))
                    }.fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                    ScanFrame().frame(width: window.width, height: window.height)
                        .position(x: window.midX, y: window.midY).allowsHitTesting(false)
                }
            }
            .frame(height: typeSize.isAccessibilitySize ? 250 : 330)
            .clipShape(RoundedRectangle(cornerRadius: ExRadius.card, style: .continuous))
            // Over the camera the controls stop growing at xxLarge, so the window
            // stays clear; VoiceOver hears the status in full.
            .overlay(alignment: .top) { controls.dynamicTypeSize(...DynamicTypeSize.xxLarge) }
            .overlay(alignment: .bottom) { statusLine.dynamicTypeSize(...DynamicTypeSize.xxLarge).padding(ExSpacing.item) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera viewfinder")
            .accessibilityIdentifier(usesFeed && feedPrimed || usesCamera ? "nutrition.scannerReady" : "nutrition.scanner")
        } else {
            BarcodeNoCamera(denied: cameraDenied, error: camera.error)
        }
    }

    /// The window codes are read in: wide and short, centred.
    static func window(in size: CGSize) -> CGRect {
        let width = size.width * 0.84, height = min(size.height * 0.5, width * 0.62)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2 - 16, width: width, height: height)
    }

    /// The simulator's stand-in camera: the code a test posted, on a pack.
    @ViewBuilder private func simulated(window: CGRect) -> some View {
        LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
        if let feedImage {
            Image(decorative: feedImage, scale: 1).resizable().interpolation(.none).scaledToFit()
                .frame(maxWidth: window.width * 0.78, maxHeight: window.height * 0.72)
                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .rotationEffect(.degrees(-2))
                .position(x: window.midX, y: window.midY).accessibilityHidden(true)
        }
    }

    private var controls: some View {
        HStack {
            if usesCamera, camera.zoom > 1.05 {
                Text("\(Double(camera.zoom).formatted(.number.precision(.fractionLength(1))))×")
                    .font(.exLabel.monospacedDigit()).foregroundStyle(.white).padding(.horizontal, 10).frame(minHeight: 32)
                    .glassEffect(.regular, in: Capsule()).accessibilityLabel("Zoomed in for small codes")
            }
            Spacer()
            if usesCamera, camera.hasTorch {
                Button(camera.torchOn ? "Turn the light off" : "Turn the light on",
                       systemImage: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") { camera.toggleTorch() }
                    .labelStyle(.iconOnly).font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityIdentifier("nutrition.scanTorch")
            }
        }.padding(ExSpacing.item)
    }

    @ViewBuilder private var statusLine: some View {
        if usesCamera, camera.lowLight, !camera.torchOn {
            Button { camera.toggleTorch() } label: {
                Label("Too dark to read. Turn on the light", systemImage: "flashlight.on.fill")
                    .font(.exLabel).foregroundStyle(.white).padding(.horizontal, ExSpacing.content).frame(minHeight: 44)
            }.background(Color.black.opacity(0.6), in: Capsule()).glassEffect(.regular.interactive(), in: Capsule())
                .accessibilityIdentifier("nutrition.scanLowLight")
        } else {
            Label(status, systemImage: statusIcon)
                .font(.exLabel).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, ExSpacing.content).padding(.vertical, ExSpacing.small).frame(minHeight: 40)
                // Dark under the glass, so white text reads over any frame, in light mode too.
                .background(Color.black.opacity(0.6), in: Capsule())
                .glassEffect(.regular, in: Capsule())
                .contentTransition(.opacity).animation(.snappy, value: status)
                .accessibilityIdentifier("nutrition.scanStatus")
        }
    }
}

/// Corner brackets for the viewfinder's window.
private struct ScanFrame: View {
    var body: some View {
        GeometryReader { geometry in
            let length: CGFloat = 26
            Path { path in
                let rect = CGRect(origin: .zero, size: geometry.size)
                for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                         (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
                    path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
                }
            }.stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}

private struct BarcodeNoCamera: View {
    let denied: Bool
    let error: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: ExSpacing.item) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: denied ? "camera.badge.ellipsis" : "barcode.viewfinder")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 48, height: 48).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: ExRadius.control))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                Text(denied ? "Allow the camera to scan" : "No camera here").font(.exH3).foregroundStyle(Color.exTextPrimary)
                Text(denied ? "Turn on camera access to scan packages. You can also type the digits under the barcode."
                     : "Type the digits printed under the barcode instead.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                if denied {
                    Button("Open camera settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.font(.exLabel).frame(minHeight: 44)
                }
                if let error { Text(error).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
            }
        }
    }
}

// MARK: - Notices

struct BarcodeNoticeCard<Actions: View>: View {
    let icon: String
    let title: String
    let gtin: GTIN?
    let message: String
    let identifier: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ExCard(accent: true) {
            Label(title, systemImage: icon).font(.exH3).foregroundStyle(Color.exTextPrimary)
            if let gtin {
                Text(BarcodeText.printed(gtin)).font(.exMono.weight(.semibold)).foregroundStyle(Color.exTextPrimary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Barcode \(BarcodeText.spoken(gtin))").accessibilityIdentifier("nutrition.barcodeShown")
            }
            Text(message).font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
            actions
        }
    }
}

// MARK: - Plate

/// What's been scanned so far, each at an amount to adjust or remove.
struct BarcodeTray: View {
    @ObservedObject var session: BarcodeScanSession
    let edit: (NutritionPlateDraft.Row) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExCard(accent: true) {
            let header = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.tight)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            header {
                ExEyebrow("Your plate · \(session.plate.rows.count) \(session.plate.rows.count == 1 ? "food" : "foods")", color: .exPrimaryText)
                if !typeSize.isAccessibilitySize { Spacer() }
                if let energy = session.plate.summary?.totals.energy {
                    Text("\(FoodFormat.kcal(energy)) kcal").font(.exStatSmall).foregroundStyle(Color.exTextPrimary)
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("nutrition.scanPlate")
            Menu {
                Picker("Meal", selection: Binding(get: { session.plate.meal }, set: { session.plate.meal = $0 })) {
                    ForEach(meals, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Label("Into \(session.plate.meal)", systemImage: "fork.knife").font(.exLabel).frame(minHeight: 44)
            }.accessibilityIdentifier("nutrition.scanMeal")
            ForEach(session.plate.rows) { row in
                BarcodeTrayRow(session: session, row: row, edit: edit)
                if row.id != session.plate.rows.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
            }
        }
    }

    private var meals: [String] {
        NutritionStore.defaultMeals.contains(session.plate.meal) ? NutritionStore.defaultMeals : NutritionStore.defaultMeals + [session.plate.meal]
    }
}

private struct BarcodeTrayRow: View {
    @ObservedObject var session: BarcodeScanSession
    let row: NutritionPlateDraft.Row
    let edit: (NutritionPlateDraft.Row) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        layout {
            Button { edit(row) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).multilineTextAlignment(.leading)
                    Text("\(session.portion(of: row)) · \(FoodFormat.kcal(row.amount.nutrients.energy)) kcal")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("Changes the amount")
            .accessibilityIdentifier("nutrition.scanRow.\(row.food.id)")
            HStack(spacing: 0) {
                if session.stepped(row, more: true) != nil {
                    stepButton("minus", "One less", more: false, enabled: session.stepped(row, more: false) != nil,
                               identifier: "nutrition.scanLess.\(row.food.id)")
                    stepButton("plus", "One more", more: true, enabled: true, identifier: "nutrition.scanMore.\(row.food.id)")
                }
                Button("Remove \(row.food.name)", systemImage: "xmark.circle.fill") { session.plate.remove(row) }
                    .labelStyle(.iconOnly).font(.title3).foregroundStyle(Color.exTextMuted).frame(width: 44, height: 44)
                    .accessibilityIdentifier("nutrition.scanRemove.\(row.food.id)")
            }
        }
    }

    private func stepButton(_ icon: String, _ title: String, more: Bool, enabled: Bool, identifier: String) -> some View {
        Button { session.step(row, more: more) } label: {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 40, height: 40)
                .background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Color.exPrimaryText : Color.exTextMuted).disabled(!enabled)
        .frame(width: 44, height: 44).accessibilityLabel("\(title) \(row.food.name)").accessibilityIdentifier(identifier)
    }
}

// MARK: - Past scans

struct BarcodeRecentScans: View {
    @ObservedObject var session: BarcodeScanSession
    let limit: Int
    let picking: Bool
    let log: (BarcodeLibrary.Scan) -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            HStack(alignment: .firstTextBaseline) {
                ExSectionHeading("Recent scans")
                Spacer()
                if session.library.history.count > limit {
                    Button("See all", action: showAll).font(.exLabel).frame(minHeight: 44).accessibilityIdentifier("nutrition.scanSeeAll")
                }
            }
            ExCard {
                // Scans that resolved since going offline come first.
                let history = session.library.history
                let scans = Array((history.filter(\.ready) + history.filter { !$0.ready }).prefix(limit))
                ForEach(scans) { scan in
                    BarcodeScanRow(session: session, scan: scan, picking: picking, log: log)
                    if scan.id != scans.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                }
            }
        }
    }
}

/// Every past scan: those found offline first, then those still waiting.
struct BarcodeHistoryView: View {
    @ObservedObject var session: BarcodeScanSession
    let picking: Bool
    let log: (BarcodeLibrary.Scan) -> Void

    var body: some View {
        let history = session.library.history
        let sections: [(String, String?, [BarcodeLibrary.Scan])] = [
            ("Ready to log", nil, history.filter(\.ready)),
            ("Waiting for a connection", nil, history.filter { $0.state == .waiting }),
            ("Scanned", nil, history.filter { !$0.ready && $0.state != .waiting }),
        ]
        ExScreen {
            if history.isEmpty {
                ExEmptyState(icon: "barcode.viewfinder", title: "No scans yet",
                             message: "Codes you scan stay here, ready to log again in one tap, offline too.", action: "Scan a barcode") {}
            }
            ForEach(sections.filter { !$0.2.isEmpty }, id: \.0) { title, detail, scans in
                VStack(alignment: .leading, spacing: ExSpacing.item) {
                    ExSectionHeading(title, detail: detail)
                    ExCard {
                        ForEach(scans) { scan in
                            BarcodeScanRow(session: session, scan: scan, picking: picking, log: log)
                                .contextMenu {
                                    Button("Remove from history", systemImage: "trash", role: .destructive) { session.library.remove(scan.gtin) }
                                }
                            if scan.id != scans.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Scan history").navigationBarTitleDisplayMode(.inline)
    }
}

struct BarcodeScanRow: View {
    @ObservedObject var session: BarcodeScanSession
    let scan: BarcodeLibrary.Scan
    let picking: Bool
    let log: (BarcodeLibrary.Scan) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let product = session.library.product(scan.gtin)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(tint).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product?.food.name ?? BarcodeText.printed(scan.gtin)).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(detail(product)).font(.exCaption).foregroundStyle(scan.ready ? Color.exSuccess : Color.exTextSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("nutrition.scanHistory.\(scan.gtin.key)")
            if product != nil {
                Button(picking ? "Add" : scan.ready ? "Log to \(scan.meal)" : "Log") { log(scan) }
                    .font(.exLabel.weight(.semibold)).foregroundStyle(Color.white)
                    .padding(.horizontal, ExSpacing.content).frame(minHeight: 44)
                    .background(Color.exActionFill, in: Capsule())
                    .accessibilityLabel("\(picking ? "Add" : "Log") \(product?.food.name ?? "")")
                    .accessibilityIdentifier("nutrition.scanRelog.\(scan.gtin.key)")
            }
        }
        .frame(minHeight: 44)
    }

    private var icon: String {
        switch scan.state {
        case .found: scan.ready ? "checkmark.icloud.fill" : "barcode"
        case .missing: "questionmark.circle"
        case .waiting: "wifi.slash"
        }
    }

    private var tint: Color {
        switch scan.state {
        case .found: scan.ready ? .exSuccess : .exPrimaryText
        case .missing: .exTextMuted
        case .waiting: .exWarning
        }
    }

    private func detail(_ product: BarcodeLibrary.Product?) -> String {
        let time = scan.scannedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
        switch scan.state {
        case .waiting: return "Waiting for a connection · scanned \(time)"
        case .missing: return "Not in the food database · \(time)"
        case .found:
            if scan.ready { return "Found · scanned offline at \(time) for \(scan.meal)" }
            guard let product, let portion = session.usualPortion(of: product.food) else { return time }
            return "\(FoodFormat.portion(portion, unit: session.unit)) · \(FoodFormat.kcal(portion.nutrients.energy)) kcal"
        }
    }
}
