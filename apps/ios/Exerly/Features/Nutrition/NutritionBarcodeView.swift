import AVFoundation
import ExerlyCore
import SwiftUI

/// Scan barcode: point the camera at one pack after another and each lands
/// on a plate that logs in one tap. A code read before resolves on this
/// device, offline too; one never seen while offline is saved for later.
/// See docs/BARCODE.md.
struct NutritionBarcodeView: View {
    let workspace: TrainingWorkspace
    let date: LocalDate
    let timeZone: TimeZone
    @ObservedObject var actions: NutritionDiaryActions
    let onLogged: ([FoodEntry]) -> Void
    /// Building a meal or recipe: a found food goes back to it at once.
    let onPicked: ((ExerlyCore.Food) -> Void)?
    @StateObject private var session: BarcodeScanSession
    @StateObject private var camera = BarcodeCamera()
    #if DEBUG
    @StateObject private var feed = BarcodeTestFeed()
    #endif
    @State private var code = ""
    @State private var codeError: String?
    @State private var cameraAllowed = false
    @State private var enteringDigits = false
    @State private var editing: NutritionPlateDraft.Row?
    @State private var creatingFor: GTIN?
    @State private var creating = false
    @State private var createdFood: ExerlyCore.Food?
    @State private var scanningLabel = false
    @State private var showingHistory = false
    @State private var discarding = false
    /// Under UI tests: how long each step took inside the app.
    @State private var timings = ""
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Building a meal: the plate an offline scan picked here joins.
    @Environment(\.barcodeStagingScope) private var stagingScope

    init(workspace: TrainingWorkspace, api: AccountAPI, date: LocalDate, meal: String,
         timeZone: TimeZone, unit: MassUnit, actions: NutritionDiaryActions,
         onPicked: ((ExerlyCore.Food) -> Void)? = nil, onLogged: @escaping ([FoodEntry]) -> Void) {
        self.workspace = workspace
        self.date = date
        self.timeZone = timeZone
        self.actions = actions
        self.onLogged = onLogged
        self.onPicked = onPicked
        _session = StateObject(wrappedValue: BarcodeScanSession(workspace: workspace, api: api, date: date, meal: meal,
                                                                unit: unit, timeZone: timeZone))
    }

    var body: some View {
        ExScreen {
            BarcodeViewfinder(camera: camera, feedImage: feedImage, feedPrimed: feedPrimed, usesCamera: usesCamera, usesFeed: usesFeed,
                              cameraDenied: cameraDenied, status: status, statusIcon: statusIcon,
                              compact: !session.plate.rows.isEmpty || session.notice.isCard)
            if let notice = session.notice { noticeCard(notice) }
            if picking == false, !session.plate.rows.isEmpty {
                BarcodeTray(session: session, edit: { editing = $0 })
            }
            digitsSection
            if !session.pastScans.isEmpty {
                BarcodeRecentScans(session: session, limit: 4, picking: picking, use: usePast) { showingHistory = true }
            }
            if session.plate.rows.isEmpty {
                HStack(spacing: ExSpacing.small) {
                    Button { dismiss() } label: { Label("Search", systemImage: "magnifyingglass") }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityLabel("Search by name")
                        .accessibilityIdentifier("nutrition.barcodeSearch")
                    Button { scanningLabel = true } label: { Label("Label", systemImage: "text.viewfinder") }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityLabel("Scan nutrition label")
                        .accessibilityIdentifier("nutrition.scanLabel")
                }
            }
        }
        .exFooter { logFooter }
        .overlay(alignment: .topLeading) {
            if !timings.isEmpty {
                Text(timings).font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("nutrition.scanTimings")
            }
        }
        .environment(\.timeZone, timeZone)
        .navigationTitle("Scan barcode").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!session.plate.rows.isEmpty)
        .toolbar {
            if !session.plate.rows.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { discarding = true }.accessibilityIdentifier("nutrition.scanCancel")
                }
            }
            if typeSize.isAccessibilitySize, !picking, !session.plate.rows.isEmpty {
                ToolbarItem(placement: .principal) { BarcodeMealMenu(session: session, compact: true) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Scan history", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .accessibilityIdentifier("nutrition.scanHistory")
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { typing = false } }
        }
        .sensoryFeedback(.success, trigger: session.successes)
        .sensoryFeedback(.warning, trigger: session.warnings)
        .task { await checkCameraPermission() }
        .task { await session.resolveWaiting() }
        .onReceive(camera.accepted) { code in Task { await accept(code) } }
        #if DEBUG
        .onReceive(feed.accepted) { code in Task { await accept(code) } }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkCameraPermission() } } else { stopSources() }
        }
        // Nothing joins the plate while a sheet is up.
        .onChange(of: presenting) { _, presenting in if presenting { stopSources() } else { startSources() } }
        .onDisappear { stopSources() }
        .navigationDestination(isPresented: $showingHistory) {
            BarcodeHistoryView(session: session, picking: picking, use: usePast)
        }
        .sheet(item: $editing) { row in
            FoodPortionStep(store: workspace.nutrition, food: row.food,
                            editing: row.entry(on: session.plate.date, meal: session.plate.meal, at: session.plate.loggedAt),
                            unit: session.unit, title: "Portion", confirm: "Apply", identifier: "nutrition.scanPortion",
                            removeTitle: "Remove from plate", onRemove: { session.plate.remove(row) },
                            onConfirm: { amount, _ in session.plate.stage(row.food, amount: amount, replacing: row) })
        }
        .sheet(isPresented: $creating, onDismiss: addCreatedFood) {
            NutritionFoodEditor(workspace: workspace, start: creatingFor.map { ExerlyCore.Food(name: "", per100g: NutrientAmounts(), barcode: $0.key) }) {
                createdFood = $0
            }
        }
        .sheet(isPresented: $scanningLabel, onDismiss: addCreatedFood) {
            NutritionLabelCaptureView(workspace: workspace) { createdFood = $0 }
        }
        .sheet(isPresented: $discarding) {
            NutritionConfirmation(title: "Discard these scans?", message: "Nothing has been logged. Your scan history keeps every code.",
                                  confirm: "Discard", cancelLabel: "Keep scanning", destructive: true) { dismiss() }
                cancel: { discarding = false }
        }
    }

    // MARK: Viewfinder

    private var picking: Bool { onPicked != nil }
    private var presenting: Bool { editing != nil || creating || scanningLabel || discarding }

    #if DEBUG
    private var feedImage: CGImage? { feed.image }
    private var feedPrimed: Bool { feed.primed }
    private var usesFeed: Bool { feed.isActive }
    #else
    private var feedImage: CGImage? { nil }
    private var feedPrimed: Bool { false }
    private var usesFeed: Bool { false }
    #endif

    private var usesCamera: Bool { !usesFeed && cameraAllowed && camera.error == nil }
    private var cameraDenied: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .denied }
    private var hasViewfinder: Bool { usesFeed || usesCamera }

    private var status: String {
        switch session.notice {
        case .added(let name)?: "Added \(name)"
        case .again(let name)?: "One more \(name)"
        case .looking?: "Looking it up…"
        case .queued?: "Code read · offline"
        case .missing?: "Code read · no match"
        case .notProduct?: "Code read · not a product"
        case .ready?, nil:
            camera.holdCloser ? "Hold it closer to read this small code"
                : session.plate.rows.isEmpty ? "Point at a barcode" : "Scan the next one, or log your plate"
        }
    }

    private var statusIcon: String {
        switch session.notice {
        case .added?, .again?: "checkmark.circle.fill"
        case .looking?: "magnifyingglass"
        case .queued?: "wifi.slash"
        case .missing?, .notProduct?: "exclamationmark.circle.fill"
        case .ready?, nil: "barcode.viewfinder"
        }
    }

    private func stopSources() {
        camera.stop()
        #if DEBUG
        feed.stop()
        #endif
    }

    private func startSources() {
        #if DEBUG
        if feed.isActive { feed.start(); return }
        #endif
        if cameraAllowed, scenePhase == .active { camera.start() }
    }

    private func checkCameraPermission() async {
        if usesFeed { startSources(); return }
        guard AVCaptureDevice.default(for: .video) != nil else {
            // Without a camera, the digits are the only way in: show them ready.
            cameraAllowed = false
            enteringDigits = true
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed = status == .authorized ? true : status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : false
        guard !Task.isCancelled else { return }
        cameraAllowed = allowed
        if !allowed { enteringDigits = true }
        startSources()
    }

    // MARK: Scans

    private func accept(_ code: ScannedCode) async {
        let accepted = Date()
        guard let food = await session.food(for: code.gtin) else { return }
        use(food)
        #if DEBUG
        if let received = feed.receivedAt {
            func ms(_ end: Date, _ start: Date) -> Int { Int(end.timeIntervalSince(start) * 1000) }
            timings = "ready \(feed.primedAt.map { ms($0, feed.started) } ?? -1) · read \(ms(accepted, received))"
                + " · on plate \(ms(Date(), accepted))"
        }
        #endif
    }

    /// A found food joins the plate, or goes back to the meal or recipe being built.
    private func use(_ food: ExerlyCore.Food) {
        if let onPicked {
            onPicked(food)
            dismiss()
        } else {
            session.add(food)
        }
    }

    /// A past scan: added to the meal being built or the plate, else logged.
    private func usePast(_ past: BarcodeScanSession.PastScan) {
        if let onPicked, let product = session.library.usable(past.gtin) {
            // The meal being built consumes an offline scan only when it logs.
            if case .pending(let scan) = past, let stagingScope {
                session.library.stage(scan.id, scope: stagingScope, foodID: product.food.id)
            }
            onPicked(product.food)
            dismiss()
            return
        }
        switch session.use(past) {
        case .logged(let entry):
            Task { await workspace.synchronize() }
            onLogged([entry])
        case .addedToPlate: showingHistory = false
        case .failed: break
        }
    }

    private func addCreatedFood() {
        guard let food = createdFood else { return }
        createdFood = nil
        if let gtin = creatingFor {
            session.library.remember(food, for: gtin, attribution: "Your food")
            creatingFor = nil
        }
        session.dismissNotice()
        use(food)
    }

    // MARK: Notices

    @ViewBuilder private func noticeCard(_ notice: BarcodeScanSession.Notice) -> some View {
        switch notice {
        case .missing(let gtin):
            BarcodeNoticeCard(icon: "barcode", title: "Not in the food database yet", gtin: gtin,
                              message: "Search for it by name, or enter it from its label once. After that, this code finds it.",
                              identifier: "nutrition.barcodeNotFound") { missActions(gtin) }
        case .notProduct(let gtin, let kind):
            BarcodeNoticeCard(icon: "tag", title: BarcodeNoticeCopy.title(kind), gtin: gtin, message: BarcodeNoticeCopy.detail(kind),
                              identifier: "nutrition.barcodeNotProduct") {
                // A store's own number can still find the person's own food for it;
                // a weighed label's number changes with each price, so it can't.
                missActions(kind == .storeInternal ? gtin : nil)
            }
        case .queued(let gtin):
            BarcodeNoticeCard(icon: "wifi.slash", title: "Saved for when you're online", gtin: gtin,
                              message: "It's looked up when you're back online, then waits in Recent scans to log to \(session.plate.meal).",
                              identifier: "nutrition.barcodeQueued") {
                Button("Keep scanning", systemImage: "barcode.viewfinder") { session.dismissNotice() }
                    .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.barcodeKeepScanning")
            }
        case .ready(let count):
            BarcodeNoticeCard(icon: "checkmark.icloud", title: "\(count) offline \(count == 1 ? "scan is" : "scans are") ready", gtin: nil,
                              message: "Found now that you're back online. Log \(count == 1 ? "it" : "them") from Recent scans.",
                              identifier: "nutrition.barcodeReady") {
                HStack(spacing: ExSpacing.small) {
                    Button("Show scans", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.barcodeShowReady")
                    Button("Not needed") { session.dismissReady() }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.barcodeDismissReady")
                }
            }
        case .added, .again, .looking: EmptyView()
        }
    }

    /// A code the database can't give a food for is never a dead end:
    /// search by name, enter it yourself, or read its label.
    @ViewBuilder private func missActions(_ gtin: GTIN?) -> some View {
        Button { dismiss() } label: { Label("Search by name", systemImage: "magnifyingglass") }
            .buttonStyle(ExActionStyle()).accessibilityIdentifier("nutrition.barcodeSearchByName")
        // Side by side, the largest sizes break the words.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small)) : AnyLayout(HStackLayout(spacing: ExSpacing.small))
        layout {
            Button("Enter it", systemImage: "square.and.pencil") { creatingFor = gtin; creating = true }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.barcodeManualFood")
            Button("Read label", systemImage: "text.viewfinder") { creatingFor = gtin; scanningLabel = true }
                .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("nutrition.barcodeScanLabel")
        }
    }

    // MARK: Digits

    private var digitsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Without a camera the digits are the only way in, so they stay open.
            if hasViewfinder {
                Button { withAnimation(.snappy) { enteringDigits.toggle() } } label: {
                    HStack {
                        Label("Type the digits instead", systemImage: "keyboard")
                        Spacer()
                        Image(systemName: "chevron.down").rotationEffect(.degrees(enteringDigits ? 180 : 0)).accessibilityHidden(true)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.font(.exLabel).buttonStyle(.plain).foregroundStyle(Color.exPrimaryText)
                    .accessibilityIdentifier("nutrition.enterBarcodeDigits")
                    .accessibilityValue(enteringDigits ? "Expanded" : "Collapsed")
            }
            if enteringDigits || !hasViewfinder {
                VStack(alignment: .leading, spacing: ExSpacing.item) {
                    TextField("Digits under the barcode", text: $code).keyboardType(.numberPad).focused($typing).font(.exStatSmall)
                        .padding(ExSpacing.item).background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                        .accessibilityIdentifier("nutrition.barcodeDigits")
                        .onChange(of: code) { _, _ in codeError = nil }
                    Button("Look up barcode") { lookUpDigits() }.buttonStyle(ExActionStyle())
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || session.notice.isLooking)
                        .accessibilityIdentifier("nutrition.lookupBarcode")
                    if let codeError {
                        Text(codeError).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("nutrition.barcodeDigitsError")
                    } else {
                        Text("Leading zeros are optional. Eight digits are tried as both EAN-8 and UPC-E.")
                            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    }
                }.padding(.top, hasViewfinder ? ExSpacing.small : 0)
            }
        }
    }

    private func lookUpDigits() {
        typing = false
        let text = code
        Task {
            switch await session.lookUp(typed: text) {
            case .food(let food):
                code = ""
                use(food)
            case .noFood: code = ""
            case .invalid: codeError = "Those digits don't make a valid barcode. Check them against the numbers under the bars."
            }
        }
    }

    // MARK: Logging

    @ViewBuilder private var logFooter: some View {
        if !picking, !session.plate.rows.isEmpty {
            let count = session.plate.rows.count
            let foods = "\(count) \(count == 1 ? "food" : "foods")"
            VStack(spacing: ExSpacing.small) {
                if let error = session.plate.error {
                    Text(error).font(.exCaption).foregroundStyle(Color.exError).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    if let entries = session.logAll() {
                        Task { await workspace.synchronize() }
                        onLogged(entries)
                    }
                } label: {
                    if session.lookingUp > 0 {
                        // A scan still being looked up joins the plate before it logs.
                        HStack(spacing: ExSpacing.small) {
                            ProgressView().tint(.white)
                            Text("Finding \(session.lookingUp) more \(session.lookingUp == 1 ? "food" : "foods")…")
                        }
                    } else {
                        // The meal is under the foods; at the largest sizes the button stays short.
                        Label(typeSize.isAccessibilitySize ? "Log \(foods)" : "Log \(foods) to \(session.plate.meal)", systemImage: "checkmark")
                    }
                }
                .buttonStyle(ExActionStyle()).disabled(!session.canLog)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .accessibilityIdentifier("nutrition.scanLogAll")
            }
            .padding(ExSpacing.page).background(Color.exBackground)
        }
    }
}

private extension Optional where Wrapped == BarcodeScanSession.Notice {
    var isLooking: Bool { if case .looking? = self { true } else { false } }

    /// The notice shows as a card under the viewfinder.
    var isCard: Bool {
        switch self {
        case .missing?, .notProduct?, .queued?, .ready?: true
        default: false
        }
    }
}
