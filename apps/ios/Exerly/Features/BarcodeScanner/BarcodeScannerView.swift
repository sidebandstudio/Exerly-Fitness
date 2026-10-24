import SwiftUI
import AVFoundation

struct BarcodeScannerView: View {
    var initialDate: CalendarDay
    var initialMealType = "snack"
    var onLogged: () -> Void = {}
    @StateObject private var camera = BarcodeCamera()
    @State private var foundFood: OpenFoodItem?
    @State private var code = ""
    @State private var format = "ean13"
    @State private var message: String?
    @State private var isLoading = false
    @State private var cameraAllowed = false
    @State private var lookupTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cameraAllowed {
                    CameraPreview(camera: camera, viewfinder: .zero)
                        .frame(height: 280)
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: 2).padding(.horizontal, 24).padding(.vertical, 52).allowsHitTesting(false) }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Camera barcode viewfinder")
                    HStack {
                        Text("Center the barcode in the frame. Tap to focus.").font(.callout)
                        Spacer()
                        Button { camera.toggleTorch() } label: {
                            Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel(camera.torchOn ? "Turn flashlight off" : "Turn flashlight on")
                    }
                } else {
                    Text("Camera unavailable. You can enter the barcode below or search for the food.")
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                        Button("Open camera settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.frame(minHeight: 44)
                    }
                }
                if let error = camera.error { Text(error).font(.callout) }
                TextField("Barcode digits", text: $code)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(minHeight: 44)
                    .accessibilityIdentifier("barcode.digits")
                Picker("Barcode format", selection: $format) {
                    Text("EAN-13").tag("ean13")
                    Text("UPC-A").tag("upca")
                    Text("EAN-8").tag("ean8")
                    Text("UPC-E").tag("upce")
                    Text("GTIN-14").tag("gtin14")
                }.pickerStyle(.menu)
                ActionButton(title: "Look up barcode", isLoading: isLoading, isDisabled: code.isEmpty) { beginLookup() }
                if let message { Text(message).font(.callout).accessibilityIdentifier("barcode.result") }
                if let food = foundFood {
                    NavigationLink {
                        FoodDetailView(food: food, initialDate: initialDate, initialMealType: initialMealType) {
                            onLogged()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(food.name).font(.headline)
                            Text("Review quantity and log to \(initialMealType)").font(.callout)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered)
                }
                Button("Scan again") {
                    lookupTask?.cancel()
                    foundFood = nil
                    message = nil
                    isLoading = false
                    camera.start()
                }.frame(minHeight: 44)
                NavigationLink("Create food with this barcode") {
                    CreateFoodView(initialBarcode: code) { food in foundFood = food }
                }.frame(minHeight: 44)
                Button("Search by name") { dismiss() }.frame(minHeight: 44)
            }.padding(20)
        }
        .background(Color.exBackground)
        .navigationTitle("Scan barcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .task { await checkPermission() }
        .onReceive(camera.accepted) { detected in
            code = detected.gtin.key
            format = "gtin14"
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            beginLookup()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await checkPermission() } }
            else { camera.stop() }
        }
        .onDisappear { lookupTask?.cancel(); camera.stop() }
    }

    private func checkPermission() async {
        guard AVCaptureDevice.default(for: .video) != nil else { cameraAllowed = false; return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed = status == .authorized ? true : status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .video) : false
        guard !Task.isCancelled else { return }
        cameraAllowed = allowed
        if allowed && scenePhase == .active && !isLoading && foundFood == nil { camera.start() }
    }

    private func beginLookup() {
        guard !isLoading else { return }
        camera.stop()
        lookupTask?.cancel()
        foundFood = nil
        message = nil
        isLoading = true
        let barcode = code
        let symbology = format
        lookupTask = Task {
            defer { isLoading = false }
            do {
                let response = try await APIClient.shared.barcodeLookup(barcode: barcode, symbology: symbology)
                try Task.checkCancellation()
                if response.found, let food = response.food { foundFood = food.toOpenFoodItem(); return }
                switch response.status {
                case "not_found": message = "This product is not in the available catalog. Create a personal food below."
                case "rate_limited": message = "The food provider is busy. Try again in a minute, or enter the food manually."
                case "invalid_code", "unsupported_format": message = response.message ?? "Check the digits and barcode format."
                default: message = "The food provider is unavailable. Try again, search by name, or create the food manually."
                }
            } catch is CancellationError { return }
            catch { message = error.localizedDescription }
        }
    }
}
