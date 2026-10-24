import AVFoundation
import Combine
import ExerlyCore
import ImageIO
import SwiftUI

// The live camera behind Scan barcode: frames go to Vision in a region of
// interest, and a code is accepted only after two agreeing reads with a
// valid check digit. See docs/BARCODE.md and the 2026-10-20 entry in
// docs/DECISIONS.md for why this isn't VisionKit's DataScanner.

/// Where accepted codes come from: the camera, or in UI tests a stand-in
/// that decodes synthetic images through the same decoder.
protocol BarcodeSource: AnyObject {
    var accepted: PassthroughSubject<ScannedCode, Never> { get }
    func start()
    func stop()
}

final class BarcodeCamera: NSObject, ObservableObject, BarcodeSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var torchOn = false
    @Published private(set) var hasTorch = false
    /// The scene has stayed too dark to read bars.
    @Published private(set) var lowLight = false
    /// A short code was seen too small to trust: hold the phone closer.
    @Published private(set) var holdCloser = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var error: String?
    let accepted = PassthroughSubject<ScannedCode, Never>()
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.exerly.barcode-camera")
    private let output = AVCaptureVideoDataOutput()
    private let decoder = BarcodeDecoder()
    private var device: AVCaptureDevice?
    private var configured = false
    private var wantsRunning = false
    private var consensus = BarcodeConsensus()
    private var advisor = LowLightAdvisor()
    /// The zoom chosen for small codes; pinching scales from it.
    private var baseZoom: CGFloat = 1
    private var pinchStart: CGFloat = 1
    private var lastTooSmall = Date.distantPast
    /// What was last published, as the camera queue knows it.
    private var reportedLowLight = false, reportedCloser = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.wantsRunning else { return }
                    self.session.startRunning()
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            if !self.configured { self.configure() }
            guard self.configured else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            // A pack accepted before the pause isn't added again on return.
            self.consensus.pause()
            self.setTorch(false)
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func toggleTorch() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorch(self.device?.torchMode != .on)
        }
    }

    /// Pinch: scales the zoom from where the pinch began.
    func pinch(_ scale: CGFloat, began: Bool) {
        queue.async { [weak self] in
            guard let self, let device = self.device else { return }
            if began { self.pinchStart = device.videoZoomFactor }
            let limit = min(device.activeFormat.videoMaxZoomFactor, self.baseZoom * 6)
            self.setZoom(min(max(self.pinchStart * scale, device.minAvailableVideoZoomFactor), limit))
        }
    }

    /// The viewfinder window, as `metadataOutputRectConverted` gives it:
    /// normalised in the sensor's landscape frame, origin top left. Vision
    /// takes it upright with its origin lower left, so it turns with the
    /// portrait frame. It's padded so a code half outside the window still reads.
    func setWindow(_ sensor: CGRect) {
        guard let region = ScannerOptics.visionRegion(sensor: sensor) else { return }
        queue.async { [weak self] in self?.decoder.regionOfInterest = region }
    }

    func focus(_ point: CGPoint) {
        queue.async { [weak self] in
            guard let device = self?.device, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Setup

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // A virtual camera switches to the ultra wide lens for codes held close.
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                                                         mediaType: .video, position: .back)
        guard let device = discovery.devices.first, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else {
            DispatchQueue.main.async { self.error = "Camera setup failed. Type the barcode digits instead." }
            return
        }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        self.device = device
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
            device.unlockForConfiguration()
        } catch {}
        baseZoom = initialZoom(for: device)
        setZoom(baseZoom)
        let torch = device.hasTorch
        DispatchQueue.main.async { self.hasTorch = torch }
        configured = true
    }

    /// Zoom so a 20 mm code fills the frame at the wide lens's closest
    /// focus, as Apple's barcode sample does, on top of a virtual camera's
    /// switch to the wide lens, and short of its switch to telephoto.
    private func initialZoom(for device: AVCaptureDevice) -> CGFloat {
        let wide = device.constituentDevices.first { $0.deviceType == .builtInWideAngleCamera } ?? device
        let lensSwitch = device.isVirtualDevice ? (device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1) : 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(wide.activeFormat.formatDescription)
        let fill = Double(dimensions.height) / Double(max(dimensions.width, 1))
        let factor = ScannerOptics.zoomFactor(minimumFocusDistance: Double(wide.minimumFocusDistance),
                                              fieldOfView: Double(wide.activeFormat.videoFieldOfView), previewFill: fill, range: 1...2.5)
        return min(lensSwitch * CGFloat(factor), device.activeFormat.videoMaxZoomFactor)
    }

    private func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
            let shown = device.isVirtualDevice
                ? factor / (device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1) : factor
            DispatchQueue.main.async { self.zoom = shown }
        } catch {}
    }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = on; if on { self.lowLight = false } }
        } catch { DispatchQueue.main.async { self.error = "The flashlight is unavailable." } }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wantsRunning, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if let brightness = Self.brightness(sampleBuffer) {
            let dark = advisor.observe(brightness: brightness, at: now, torchOn: device?.torchMode == .on)
            if dark != reportedLowLight {
                reportedLowLight = dark
                DispatchQueue.main.async { self.lowLight = dark }
            }
        }
        let frame = decoder.decode(pixels, orientation: .right)
        if frame.tooSmall > 0 { lastTooSmall = now }
        let closer = frame.codes.isEmpty && now.timeIntervalSince(lastTooSmall) < 1.5
        if closer != reportedCloser {
            reportedCloser = closer
            DispatchQueue.main.async { self.holdCloser = closer }
        }
        for code in consensus.observe(frame.codes, at: now) {
            DispatchQueue.main.async { self.accepted.send(code) }
        }
    }

    /// The frame's EXIF BrightnessValue.
    private static func brightness(_ buffer: CMSampleBuffer) -> Double? {
        guard let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: buffer, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                as? [String: Any],
              let exif = attachments[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        return exif[kCGImagePropertyExifBrightnessValue as String] as? Double
    }
}

final class CameraHostView: UIView {
    var camera: BarcodeCamera?
    /// The viewfinder window inside this view.
    var viewfinder = CGRect.zero
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        camera?.setWindow(preview.metadataOutputRectConverted(fromLayerRect: viewfinder))
    }

    @objc func focusAtTap(_ tap: UITapGestureRecognizer) {
        camera?.focus(preview.captureDevicePointConverted(fromLayerPoint: tap.location(in: self)))
    }

    @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
        camera?.pinch(pinch.scale, began: pinch.state == .began)
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: BarcodeCamera
    let viewfinder: CGRect
    func makeUIView(context: Context) -> CameraHostView {
        let view = CameraHostView()
        view.camera = camera
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspectFill
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(CameraHostView.focusAtTap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: view, action: #selector(CameraHostView.pinched(_:))))
        return view
    }
    func updateUIView(_ uiView: CameraHostView, context: Context) {
        uiView.viewfinder = viewfinder
        uiView.setNeedsLayout()
    }
    static func dismantleUIView(_ uiView: CameraHostView, coordinator: ()) {
        uiView.camera?.stop()
        uiView.preview.session = nil
    }
}
