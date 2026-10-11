import ExerlyCore
import SwiftData
import SwiftUI

/// Progress → Photos for the signed-in account.
struct PhotosTab: View {
    let workspace: TrainingWorkspace?
    let unit: MassUnit
    let timeZone: TimeZone
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        if let account = auth.currentUser?.id {
            ProgressPhotosView(store: ProgressPhotoStore(accountID: account), workspace: workspace, unit: unit, timeZone: timeZone,
                               email: auth.currentUser?.email)
                .id(account)
        } else {
            LoadingStateView(message: "Opening your photos…")
        }
    }
}

/// Front, side and back photos by date, kept on this device for one account,
/// with a comparison of any two dates and sharing only when asked.
struct ProgressPhotosView: View {
    @StateObject var store: ProgressPhotoStore
    let workspace: TrainingWorkspace?
    let unit: MassUnit
    let timeZone: TimeZone
    let email: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var adding: PhotoAddRequest?
    @State private var viewing: ViewerRequest?
    @State private var comparing = false
    @State private var error: String?

    init(store: @autoclosure @escaping () -> ProgressPhotoStore, workspace: TrainingWorkspace?, unit: MassUnit, timeZone: TimeZone,
         email: String?) {
        _store = StateObject(wrappedValue: store())
        self.workspace = workspace
        self.unit = unit
        self.timeZone = timeZone
        self.email = email
    }

    struct ViewerRequest: Identifiable {
        let date: LocalDate
        let start: ProgressPhotoStore.Photo
        var id: UUID { start.id }
    }

    private var today: LocalDate { LocalDate(Date(), in: timeZone) }

    var body: some View {
        let trends = trendWeights
        ExScreen {
            if store.photos.isEmpty {
                ExEmptyState(icon: "camera", title: "Progress photos",
                             message: "Front, side and back, every few weeks, show change the scale can't. Photos stay on this "
                                + "device and leave it only when you share them.",
                             action: "Add photos", actionID: "photos.add") { adding = PhotoAddRequest(date: today) }
            } else {
                header
                ForEach(store.dates, id: \.self) { date in dateCard(date, trend: trends[date]) }
            }
            if let error { Text(error).font(.exCaption).foregroundStyle(Color.exError) }
        }
        .navigationDestination(isPresented: $comparing) {
            PhotoCompareView(store: store, unit: unit, trends: trends, today: today)
        }
        .sheet(item: $adding) { request in
            PhotoAddSheet(store: store, request: request, today: today)
        }
        .sheet(item: $viewing) { request in
            PhotoViewer(store: store, date: request.date, start: request.start, today: today)
        }
        .task(id: store.folder) { adoptOlderPhotos() }
    }

    private var header: some View {
        ExCard {
            HStack(spacing: ExSpacing.small) {
                Image(systemName: "lock.fill").font(.exCaption).foregroundStyle(Color.exTextSecondary).accessibilityHidden(true)
                Text("On this device only. Shared only when you choose to.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: ExSpacing.small))
                : AnyLayout(HStackLayout(spacing: ExSpacing.small))
            layout {
                Button { adding = PhotoAddRequest(date: today) } label: { Label("Add photos", systemImage: "plus") }
                    .buttonStyle(ExActionStyle()).accessibilityIdentifier("photos.add")
                Button { comparing = true } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                    .buttonStyle(ExActionStyle(secondary: true)).disabled(store.dates.count < 2)
                    .accessibilityHint(store.dates.count < 2 ? "Needs photos on two dates" : "")
                    .accessibilityIdentifier("photos.compare")
            }
        }
    }

    private func dateCard(_ date: LocalDate, trend: Double?) -> some View {
        ExCard {
            HStack(alignment: .firstTextBaseline) {
                Text(BodyFormat.day(date, today: today)).font(.exH3).foregroundStyle(Color.exTextPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: ExSpacing.small)
                if let trend {
                    Text("Trend \(BodyFormat.weight(trend, unit))").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: ExSpacing.small), count: typeSize.isAccessibilitySize ? 1 : 3)
            LazyVGrid(columns: columns, spacing: ExSpacing.small) {
                ForEach(ProgressPhotoStore.Pose.allCases) { pose in slot(date, pose) }
            }
        }
    }

    @ViewBuilder
    private func slot(_ date: LocalDate, _ pose: ProgressPhotoStore.Pose) -> some View {
        let day = BodyFormat.day(date, today: today)
        if let photo = store.photo(on: date, pose: pose) {
            let extra = store.photos(on: date).filter { $0.pose == pose }.count - 1
            Button { viewing = ViewerRequest(date: date, start: photo) } label: {
                PhotoTile(image: store.thumbnail(photo), caption: pose.title, badge: extra > 0 ? "+\(extra)" : nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(pose.title) photo, \(day)")
            .accessibilityHint("Opens it to view, share or delete")
            .accessibilityIdentifier("photos.slot.\(date).\(pose.rawValue)")
        } else {
            Button { adding = PhotoAddRequest(date: date, pose: pose) } label: {
                PhotoTile(image: nil, caption: pose.title, badge: nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a \(pose.rawValue) photo for \(day)")
            .accessibilityIdentifier("photos.slot.\(date).\(pose.rawValue)")
        }
    }

    /// The trend weight on each day with photos, for captions.
    private var trendWeights: [LocalDate: Double] {
        guard let workspace else { return [:] }
        let dates = Set(store.dates)
        return Dictionary(BodyEstimates.shared.estimates(workspace.nutrition, through: today)
            .filter { dates.contains($0.date) }.map { ($0.date, $0.trend) }, uniquingKeysWith: { a, _ in a })
    }

    /// Photos an earlier version saved for this account's email in the shared
    /// store move here once, as front photos on their dates. Each is removed
    /// from the old store only after its copy is saved.
    private func adoptOlderPhotos() {
        guard let email, !email.isEmpty else { return }
        let descriptor = FetchDescriptor<ProgressPhoto>(predicate: #Predicate { $0.userId == email })
        guard let older = try? modelContext.fetch(descriptor), !older.isEmpty else { return }
        for photo in older {
            guard let data = photo.imageData else { continue }
            do {
                try store.add(data, date: LocalDate(photo.date, in: timeZone), pose: .front, addedAt: photo.date)
                modelContext.delete(photo)
            } catch { self.error = "Some older photos couldn't be moved. They're still on this device." }
        }
        try? modelContext.save()
    }
}

/// A photo or an empty slot, 3:4, with its pose under it.
struct PhotoTile: View {
    let image: UIImage?
    let caption: String
    let badge: String?

    var body: some View {
        VStack(spacing: 4) {
            Color.exSurface2
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(Color.exPrimaryText)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.exSmall.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous))
                .overlay {
                    if image == nil {
                        RoundedRectangle(cornerRadius: ExRadius.control, style: .continuous)
                            .strokeBorder(Color.exBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
            Text(caption).font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .contentShape(Rectangle())
    }
}
