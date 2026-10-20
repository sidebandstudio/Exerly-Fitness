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
    /// Something to read under it: at the largest sizes it gives way.
    var compact = false
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
            // At the largest sizes it narrows to a strip once there's something to read,
            // still scanning, so the plate and its foods fit above Log.
            .frame(height: typeSize.isAccessibilitySize ? (compact ? 150 : 260) : 330)
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExCard(accent: true) {
            Group {
                if typeSize.isAccessibilitySize { Text(title) } else { Label(title, systemImage: icon) }
            }.font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
            if let gtin {
                Text(BarcodeText.printed(gtin)).font(.exMono.weight(.semibold)).foregroundStyle(Color.exTextPrimary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Barcode \(BarcodeText.spoken(gtin))").accessibilityIdentifier("nutrition.barcodeShown")
            }
            // At the largest sizes what to do comes first, on screen; the why follows.
            if typeSize.isAccessibilitySize { actions }
            Text(message).font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
            if !typeSize.isAccessibilitySize { actions }
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
        let count = session.plate.rows.count
        let energy = (session.plate.summary?.totals.energy).map { "\(FoodFormat.kcal($0)) kcal" }
        ExCard(accent: true) {
            if typeSize.isAccessibilitySize {
                // One small line, so the foods themselves are on screen at the largest sizes.
                Text(["\(count) \(count == 1 ? "food" : "foods")", energy].compactMap { $0 }.joined(separator: " · "))
                    .font(.exCaption.weight(.semibold)).foregroundStyle(Color.exPrimaryText).accessibilityIdentifier("nutrition.scanPlate")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    ExEyebrow("Your plate · \(count) \(count == 1 ? "food" : "foods")", color: .exPrimaryText)
                    Spacer()
                    if let energy { Text(energy).font(.exStatSmall).foregroundStyle(Color.exTextPrimary) }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("nutrition.scanPlate")
            }
            ForEach(session.plate.rows) { row in
                BarcodeTrayRow(session: session, row: row, edit: edit)
                if !typeSize.isAccessibilitySize || row.id != session.plate.rows.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
            }
            // At the largest sizes the meal is chosen in the navigation bar.
            if !typeSize.isAccessibilitySize { BarcodeMealMenu(session: session) }
            BarcodeAttribution(lines: session.plateAttributions)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// Which meal the plate logs to.
struct BarcodeMealMenu: View {
    @ObservedObject var session: BarcodeScanSession
    var compact = false

    var body: some View {
        Menu {
            Picker("Meal", selection: Binding(get: { session.plate.meal }, set: { session.plate.meal = $0 })) {
                ForEach(meals, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            if compact {
                HStack(spacing: ExSpacing.tight) {
                    Text("Into \(session.plate.meal)")
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).accessibilityHidden(true)
                }.font(.exLabel)
            } else {
                Label("Into \(session.plate.meal)", systemImage: "fork.knife").font(.exLabel).frame(minHeight: 44)
            }
        }
        .accessibilityLabel("Meal, \(session.plate.meal)").accessibilityIdentifier("nutrition.scanMeal")
    }

    private var meals: [String] {
        NutritionStore.defaultMeals.contains(session.plate.meal) ? NutritionStore.defaultMeals : NutritionStore.defaultMeals + [session.plate.meal]
    }
}

/// The credit for database foods shown, as Open Food Facts's ODbL requires:
/// one short line, with a link to the source and its terms.
struct BarcodeAttribution: View {
    let lines: [String]

    var body: some View {
        let credits = lines.map(FoodDataCredit.short)
        if let first = credits.first {
            HStack(spacing: ExSpacing.tight) {
                Text(credits.map(\.label).joined(separator: " · ")).lineLimit(1)
                if let url = first.url {
                    Link(destination: url) { Image(systemName: "info.circle") }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("About the food data: \(lines.joined(separator: " "))")
                }
            }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            .accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.scanAttribution")
        }
    }
}

/// A row's amount, marked as the thing to tap to change it.
private struct BarcodeAmountLink: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.tight) {
            Image(systemName: "pencil").font(.exCaption.weight(.semibold)).accessibilityHidden(true)
            Text(text).font(.exCaption).multilineTextAlignment(.leading)
        }
        .foregroundStyle(Color.exPrimaryText)
    }
}

private struct BarcodeTrayRow: View {
    @ObservedObject var session: BarcodeScanSession
    let row: NutritionPlateDraft.Row
    let edit: (NutritionPlateDraft.Row) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize { compactRow } else { fullRow }
    }

    /// The largest sizes: a list of names and amounts. The amount and Remove
    /// are a tap away in the portion sheet, and VoiceOver adjusts and removes
    /// from the row.
    private var compactRow: some View {
        Button { edit(row) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).multilineTextAlignment(.leading).lineLimit(2)
                BarcodeAmountLink(text: "\(session.portion(of: row)) · \(FoodFormat.kcal(row.amount.nutrients.energy)) kcal").lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityHint("Edits the portion or removes it")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.step(row, more: true)
            case .decrement: session.step(row, more: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Remove") { session.plate.remove(row) }
        .accessibilityIdentifier("nutrition.scanRow.\(row.food.id)")
    }

    private var fullRow: some View {
        HStack(spacing: ExSpacing.small) {
            Button { edit(row) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).multilineTextAlignment(.leading)
                    BarcodeAmountLink(text: "\(session.portion(of: row)) · \(FoodFormat.kcal(row.amount.nutrients.energy)) kcal")
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHint("Edits the portion")
            .accessibilityIdentifier("nutrition.scanRow.\(row.food.id)")
            HStack(spacing: 0) {
                if session.stepped(row, more: true) != nil {
                    stepButton("minus", "One less", more: false, enabled: session.stepped(row, more: false) != nil,
                               identifier: "nutrition.scanLess.\(row.food.id)")
                    stepButton("plus", "One more", more: true, enabled: true, identifier: "nutrition.scanMore.\(row.food.id)")
                }
                Button("Remove \(row.food.name)", systemImage: "xmark.circle.fill") { session.plate.remove(row) }
                    .labelStyle(.iconOnly).font(.title3).foregroundStyle(Color.exTextMuted).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("nutrition.scanRemove.\(row.food.id)")
            }
        }
    }

    private func stepButton(_ icon: String, _ title: String, more: Bool, enabled: Bool, identifier: String) -> some View {
        Button { session.step(row, more: more) } label: {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(minWidth: 40, minHeight: 40)
                .background(Color.exSurface2, in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Color.exPrimaryText : Color.exTextMuted).disabled(!enabled)
        .frame(minWidth: 44, minHeight: 44).accessibilityLabel("\(title) \(row.food.name)").accessibilityIdentifier(identifier)
    }
}

// MARK: - Past scans

struct BarcodeRecentScans: View {
    @ObservedObject var session: BarcodeScanSession
    let limit: Int
    let picking: Bool
    let use: (BarcodeScanSession.PastScan) -> Void
    let showAll: () -> Void

    var body: some View {
        let all = session.pastScans
        let scans = Array(all.prefix(limit))
        VStack(alignment: .leading, spacing: ExSpacing.item) {
            HStack(alignment: .firstTextBaseline) {
                ExSectionHeading("Recent scans")
                Spacer()
                if all.count > limit {
                    Button("See all", action: showAll).font(.exLabel).frame(minHeight: 44).accessibilityIdentifier("nutrition.scanSeeAll")
                }
            }
            ExCard {
                ForEach(scans) { scan in
                    BarcodeScanRow(session: session, past: scan, picking: picking, use: use)
                    if scan.id != scans.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                }
                BarcodeAttribution(lines: session.attributions(for: scans))
            }
        }
        // A list: at the largest sizes it stops growing with the tray's.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}

/// Every past scan: offline ones found since first, then those still waiting.
struct BarcodeHistoryView: View {
    @ObservedObject var session: BarcodeScanSession
    let picking: Bool
    let use: (BarcodeScanSession.PastScan) -> Void

    var body: some View {
        let all = session.pastScans
        let sections: [(String, [BarcodeScanSession.PastScan])] = [
            ("Ready to log", all.filter { if case .pending(let scan) = $0 { scan.state == .ready } else { false } }),
            ("Waiting for a connection", all.filter { if case .pending(let scan) = $0 { scan.state == .waiting } else { false } }),
            ("Not found once online", all.filter { if case .pending(let scan) = $0 { scan.state == .missing } else { false } }),
            ("Scanned", all.filter { if case .scan = $0 { true } else { false } }),
        ]
        ExScreen {
            if all.isEmpty {
                ExEmptyState(icon: "barcode.viewfinder", title: "No scans yet",
                             message: "Codes you scan stay here, ready to log again in one tap, offline too.", action: "Scan a barcode") {}
            }
            ForEach(sections.filter { !$0.1.isEmpty }, id: \.0) { title, scans in
                VStack(alignment: .leading, spacing: ExSpacing.item) {
                    ExSectionHeading(title)
                    ExCard {
                        ForEach(scans) { scan in
                            BarcodeScanRow(session: session, past: scan, picking: picking, use: use)
                                .contextMenu {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        switch scan {
                                        case .pending(let pending): session.library.acknowledge(pending.id)
                                        case .scan(let past): session.library.remove(past.gtin)
                                        }
                                    }
                                }
                            if scan.id != scans.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                        }
                    }
                }
            }
            BarcodeAttribution(lines: session.attributions(for: all))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .navigationTitle("Scan history").navigationBarTitleDisplayMode(.inline)
    }
}

struct BarcodeScanRow: View {
    @ObservedObject var session: BarcodeScanSession
    let past: BarcodeScanSession.PastScan
    let picking: Bool
    let use: (BarcodeScanSession.PastScan) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let product = session.library.usable(past.gtin)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            HStack(alignment: .top, spacing: ExSpacing.item) {
                // Decorative; the text says the same, so it gives way at the largest sizes.
                if !typeSize.isAccessibilitySize {
                    Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(tint).frame(width: 24).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(product?.food.name ?? BarcodeText.printed(past.gtin)).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Text(detail(product)).font(.exCaption).foregroundStyle(isReady ? Color.exSuccess : Color.exTextSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("nutrition.scanHistory.\(past.gtin.key)")
            if let product {
                Button(actionTitle) { use(past) }
                    .font(.exLabel.weight(.semibold)).foregroundStyle(Color.white)
                    .padding(.horizontal, ExSpacing.content).frame(minHeight: 44)
                    .background(Color.exActionFill, in: Capsule())
                    .accessibilityLabel("\(actionTitle), \(product.food.name)")
                    .accessibilityIdentifier(identifier)
            }
        }
        .frame(minHeight: 44)
    }

    private var isReady: Bool { if case .pending(let scan) = past { scan.state == .ready } else { false } }

    /// With foods on the plate, a past scan joins them instead of logging alone.
    private var actionTitle: String {
        if picking || session.pastScansJoinThePlate { return picking ? "Add" : "Add to plate" }
        if case .pending(let scan) = past { return "Log to \(scan.meal)" }
        return "Log"
    }

    private var identifier: String {
        switch past {
        case .pending(let scan): "nutrition.scanRelog.\(scan.gtin.key).\(scan.meal)"
        case .scan(let scan): "nutrition.scanRelog.\(scan.gtin.key)"
        }
    }

    private var icon: String {
        switch past {
        case .pending(let scan): scan.state == .ready ? "checkmark.icloud.fill" : scan.state == .waiting ? "wifi.slash" : "questionmark.circle"
        case .scan(let scan): scan.state == .missing ? "questionmark.circle" : "barcode"
        }
    }

    private var tint: Color {
        switch past {
        case .pending(let scan): scan.state == .ready ? .exSuccess : scan.state == .waiting ? .exWarning : .exTextMuted
        case .scan(let scan): scan.state == .missing ? .exTextMuted : .exPrimaryText
        }
    }

    private func detail(_ product: BarcodeLibrary.Product?) -> String {
        func time(_ date: Date) -> String { date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)) }
        switch past {
        case .pending(let scan):
            switch scan.state {
            case .waiting: return "Waiting for a connection · scanned \(time(scan.scannedAt)) for \(scan.meal)"
            case .ready: return "Found · scanned offline at \(time(scan.scannedAt)) for \(scan.meal)"
            case .missing: return "Not in the food database · scanned \(time(scan.scannedAt))"
            }
        case .scan(let scan):
            if scan.state == .missing { return "Not in the food database · \(time(scan.scannedAt))" }
            guard let product, let portion = session.usualPortion(of: product.food) else { return time(scan.scannedAt) }
            return "\(FoodFormat.portion(portion, unit: session.unit)) · \(FoodFormat.kcal(portion.nutrients.energy)) kcal"
        }
    }
}
