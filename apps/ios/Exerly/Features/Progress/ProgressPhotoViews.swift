import ExerlyCore
import PhotosUI
import SwiftUI
import UIKit

typealias PhotoPose = ProgressPhotoStore.Pose

/// What the add sheet opens on: a date, and the pose tapped, if any.
struct PhotoAddRequest: Identifiable {
    let id = UUID()
    var date: LocalDate
    var pose: PhotoPose?
}

/// Front, side and back for one date, each from the library or the camera.
struct PhotoAddSheet: View {
    @ObservedObject var store: ProgressPhotoStore
    let request: PhotoAddRequest
    let today: LocalDate
    @State private var date: LocalDate
    @State private var chosen: [PhotoPose: Data] = [:]
    @State private var picking: PhotoPose?
    @State private var shooting: PhotoPose?
    @State private var item: PhotosPickerItem?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A UI test can't reach the system picker's library, so its launch
    /// supplies synthetic images, used in turn, across sheets, in place of the picker.
    private static let testImages: [Data] = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        ? (ProcessInfo.processInfo.environment["EXERLY_TEST_PHOTOS"] ?? "").split(separator: ",")
            .compactMap { Data(base64Encoded: String($0)) } : []

    init(store: ProgressPhotoStore, request: PhotoAddRequest, today: LocalDate) {
        self.store = store
        self.request = request
        self.today = today
        _date = State(initialValue: request.date)
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                ExCard(accent: true) {
                    BodyDateRow {
                        DatePicker("Date", selection: Binding(get: { BodyDates.anchor(date) }, set: { date = min(BodyDates.date($0), today) }),
                                   in: ...BodyDates.anchor(today), displayedComponents: .date)
                            .font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).tint(Color.exPrimaryText)
                            .environment(\.calendar, BodyDates.calendar).environment(\.timeZone, BodyDates.utc)
                            .accessibilityIdentifier("photoAdd.date")
                    }
                    Text("Same spot, same light, same time of day makes the comparison fair.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
                let columns = Array(repeating: GridItem(.flexible(), spacing: ExSpacing.small), count: typeSize.isAccessibilitySize ? 1 : 3)
                LazyVGrid(columns: columns, spacing: ExSpacing.small) {
                    ForEach(PhotoPose.allCases) { pose in slot(pose) }
                }
                if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError) }
            }
            .exFooter {
                Button(action: save) {
                    Text(chosen.isEmpty ? "Choose a photo" : "Save \(chosen.count) \(chosen.count == 1 ? "photo" : "photos")")
                }
                .buttonStyle(ExActionStyle()).disabled(chosen.isEmpty)
                .accessibilityIdentifier("photoAdd.save")
                .padding(.horizontal, ExSpacing.page).padding(.vertical, ExSpacing.small)
                .background(Color.exBackground)
            }
            .navigationTitle("Add photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("photoAdd.cancel") }
            }
        }
        .interactiveDismissDisabled(!chosen.isEmpty)
        .photosPicker(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), selection: $item, matching: .images)
        .onChange(of: item) { _, item in
            guard let item, let pose = picking else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { chosen[pose] = data } else {
                    error = "That photo couldn't be read. Try another."
                }
                self.item = nil
                picking = nil
            }
        }
        .fullScreenCover(item: $shooting) { pose in
            CameraPicker { data in chosen[pose] = data }.ignoresSafeArea()
        }
    }

    private func slot(_ pose: PhotoPose) -> some View {
        let image = chosen[pose].flatMap(UIImage.init(data:))
        return Menu {
            Button("Photo library", systemImage: "photo.on.rectangle") { choose(pose) }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { shooting = pose }
            }
            if chosen[pose] != nil {
                Button("Remove", systemImage: "trash", role: .destructive) { chosen[pose] = nil }
            }
        } label: {
            PhotoTile(image: image, caption: pose.title, badge: nil)
                .overlay {
                    if request.pose == pose, image == nil {
                        RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous).strokeBorder(Color.exAccent, lineWidth: 1.5)
                            .padding(.bottom, 22)
                    }
                }
        }
        .accessibilityLabel(image == nil ? "Add \(pose.rawValue) photo" : "\(pose.title) photo chosen")
        .accessibilityHint("Choose from the library or the camera")
        .accessibilityIdentifier("photoAdd.slot.\(pose.rawValue)")
    }

    private func choose(_ pose: PhotoPose) {
        guard !Self.testImages.isEmpty else { picking = pose; return }
        chosen[pose] = Self.testImages[(store.photos.count + chosen.count) % Self.testImages.count]
    }

    private func save() {
        do {
            for pose in PhotoPose.allCases { if let data = chosen[pose] { try store.add(data, date: date, pose: pose) } }
        } catch {
            self.error = "The photos couldn't be saved. Check your iPhone has space, then try again."
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

/// One date's photos, paged, with Share, Move to another pose and Delete.
struct PhotoViewer: View {
    @ObservedObject var store: ProgressPhotoStore
    let date: LocalDate
    let today: LocalDate
    @State private var current: UUID
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(store: ProgressPhotoStore, date: LocalDate, start: ProgressPhotoStore.Photo, today: LocalDate) {
        self.store = store
        self.date = date
        self.today = today
        _current = State(initialValue: start.id)
    }

    var body: some View {
        let photos = store.photos(on: date)
        let photo = photos.first { $0.id == current } ?? photos.first
        let title = "\(photo?.pose.title ?? "Photo") · \(BodyFormat.day(date, today: today))"
        NavigationStack {
            TabView(selection: $current) {
                ForEach(photos) { photo in
                    Group {
                        if let image = store.image(photo) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("\(photo.pose.title) photo, \(BodyFormat.day(date, today: today))")
                        } else {
                            Text("This photo couldn't be opened.").foregroundStyle(Color.exTextSecondary)
                        }
                    }
                    .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("photoViewer.done") }
                if let photo, let image = store.image(photo) {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share this photo")
                        .accessibilityIdentifier("photoViewer.share")
                    }
                }
                if let photo {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Pose", selection: Binding(get: { photo.pose }, set: { try? store.setPose($0, for: photo) })) {
                                ForEach(PhotoPose.allCases) { Text($0.title).tag($0) }
                            }
                            Button("Delete photo", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("More")
                            .accessibilityIdentifier("photoViewer.more")
                    }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    guard let photo else { return }
                    try? store.delete(photo)
                    if store.photos(on: date).isEmpty { dismiss() } else if let next = store.photos(on: date).first { current = next.id }
                }
            } message: {
                Text("It's only on this iPhone, so it can't be recovered.")
            }
        }
    }
}

/// Two dates of one pose, side by side or under a slider, shared as one
/// image only when asked.
struct PhotoCompareView: View {
    @ObservedObject var store: ProgressPhotoStore
    let unit: MassUnit
    let trends: [LocalDate: Double]
    let today: LocalDate
    @State private var pose: PhotoPose = .front
    @State private var before: LocalDate?
    @State private var after: LocalDate?
    @State private var mode: Mode = .sideBySide
    @State private var split = 0.5
    @Environment(\.dynamicTypeSize) private var typeSize

    enum Mode: String, CaseIterable, Hashable {
        case sideBySide = "Side by side", slider = "Slider"
    }

    private func dates(_ pose: PhotoPose) -> [LocalDate] { store.dates.filter { store.photo(on: $0, pose: pose) != nil } }

    private var poses: [PhotoPose] { PhotoPose.allCases.filter { dates($0).count >= 2 } }

    var body: some View {
        let dates = dates(pose)
        let first = before.flatMap { dates.contains($0) ? $0 : nil } ?? dates.last
        let second = after.flatMap { dates.contains($0) ? $0 : nil } ?? dates.first
        ExScreen {
            if poses.isEmpty {
                Text("Add the same pose on two dates to compare them.").font(.exBody).foregroundStyle(Color.exTextSecondary)
            } else {
                if poses.count > 1 {
                    ExSegmentedControl(values: poses, selection: $pose) { $0.title }.accessibilityIdentifier("compare.pose")
                }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
                    : AnyLayout(HStackLayout(spacing: ExSpacing.small))
                layout {
                    datePicker("Before", selection: $before, shown: first, dates: dates, identifier: "compare.before")
                    datePicker("After", selection: $after, shown: second, dates: dates, identifier: "compare.after")
                }
                ExSegmentedControl(values: Mode.allCases, selection: $mode) { $0.rawValue }.accessibilityIdentifier("compare.mode")
                if let first, let second, let a = store.photo(on: first, pose: pose).flatMap(store.image),
                   let b = store.photo(on: second, pose: pose).flatMap(store.image) {
                    switch mode {
                    case .sideBySide: sideBySide(a, first, b, second)
                    case .slider: slider(a, first, b, second)
                    }
                    if let shared = composite(a, first, b, second) {
                        ShareLink(item: Image(uiImage: shared),
                                  preview: SharePreview("\(pose.title), \(BodyFormat.shortDate(first)) and \(BodyFormat.shortDate(second))",
                                                        image: Image(uiImage: shared))) {
                            Label("Share comparison", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ExActionStyle(secondary: true))
                        .accessibilityIdentifier("compare.share")
                    }
                }
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !poses.contains(pose), let first = poses.first { pose = first } }
    }

    private func datePicker(_ title: String, selection: Binding<LocalDate?>, shown: LocalDate?, dates: [LocalDate],
                            identifier: String) -> some View {
        Menu {
            Picker(title, selection: Binding(get: { shown ?? today }, set: { selection.wrappedValue = $0 })) {
                ForEach(dates, id: \.self) { Text(BodyFormat.day($0, today: today)).tag($0) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                HStack {
                    Text(shown.map { BodyFormat.day($0, today: today) } ?? "–").font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.exCaption).foregroundStyle(Color.exTextMuted)
                }
            }
            .padding(.horizontal, ExSpacing.item).padding(.vertical, ExSpacing.small).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
        }
        .accessibilityLabel("\(title), \(shown.map { BodyFormat.day($0, today: today) } ?? "none")")
        .accessibilityIdentifier(identifier)
    }

    private func caption(_ date: LocalDate) -> String {
        [BodyFormat.day(date, today: today), trends[date].map { BodyFormat.weight($0, unit) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func sideBySide(_ a: UIImage, _ first: LocalDate, _ b: UIImage, _ second: LocalDate) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.item))
            : AnyLayout(HStackLayout(alignment: .top, spacing: ExSpacing.small))
        return layout {
            ForEach(Array([(a, first), (b, second)].enumerated()), id: \.offset) { _, pair in
                let (image, date) = pair
                VStack(spacing: 4) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
                    Text(caption(date)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pose.title) photo, \(caption(date))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compare.sideBySide")
    }

    private func slider(_ a: UIImage, _ first: LocalDate, _ b: UIImage, _ second: LocalDate) -> some View {
        VStack(spacing: 4) {
            Color.exSurface2.aspectRatio(b.size.width / max(b.size.height, 1), contentMode: .fit)
                .frame(maxHeight: 520)
                .overlay {
                    GeometryReader { proxy in
                        let x = proxy.size.width * split
                        ZStack(alignment: .leading) {
                            Image(uiImage: b).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            Image(uiImage: a).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                .mask(alignment: .leading) { Rectangle().frame(width: x) }
                            Rectangle().fill(Color.white).frame(width: 2).offset(x: x - 1)
                            Circle().fill(Color.white).frame(width: 30, height: 30)
                                .overlay { Image(systemName: "arrow.left.and.right").font(.caption.weight(.bold)).foregroundStyle(Color.exPrimary) }
                                .offset(x: x - 15).frame(maxHeight: .infinity)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            split = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                        })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
            HStack {
                Text("Before · \(caption(first))")
                Spacer(minLength: ExSpacing.small)
                Text("After · \(caption(second))")
            }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Comparison slider. \(caption(first)) left of the line, \(caption(second)) right of it")
        .accessibilityValue("\(Int((split * 100).rounded())) percent before")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(split + 0.1, 1)
            case .decrement: split = max(split - 0.1, 0)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("compare.slider")
    }

    /// Both photos side by side with their dates, as one image to share.
    private func composite(_ a: UIImage, _ first: LocalDate, _ b: UIImage, _ second: LocalDate) -> UIImage? {
        let content = HStack(alignment: .top, spacing: 12) {
            ForEach(Array([(a, first), (b, second)].enumerated()), id: \.offset) { _, pair in
                let (image, date) = pair
                VStack(spacing: 8) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 540)
                    Text(caption(date)).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .padding(24).background(Color(red: 0.06, green: 0.05, blue: 0.09))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.uiImage
    }
}

/// The camera, for a photo taken now.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.onPicked(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
