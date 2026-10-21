import ExerlyCore
import SwiftUI

/// Exports everything, free and at once: a zip with the JSON (the file Exerly
/// imports back), a CSV per kind of data and a workbook, or the JSON alone.
/// Online it includes what only the server keeps; offline, or if the server
/// is slow, it's made from this device's copy and says so. The files are
/// made by ExerlyCore's `ExportFiles`. PARITY I02, I14.
struct DataExportView: View {
    let actions: AccountManagementActions
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var exportFile: ExportShareFile?
    @State private var busy: Format?
    @State private var error: String?
    /// The phone's copy, made when the account couldn't be reached, and why:
    /// said before it's shared, so nobody shares less than they meant to.
    @State private var fallback: (file: ExportShareFile, why: String)?
    @State private var task: Task<Void, Never>?
    @AccessibilityFocusState private var errorFocused: Bool

    enum Format { case everything, json }

    /// How long to wait for the server before exporting this device's copy.
    static let serverWait: Duration = .seconds(6)

    private var deviceOnly: Bool { sync.isOffline && actions.exportDeviceData != nil }

    var body: some View {
        ExScreen {
            ExCard(accent: true) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: deviceOnly ? "iphone.and.arrow.forward" : "square.and.arrow.up.on.square")
                        .font(.system(size: 26, weight: .medium)).foregroundStyle(Color.exPrimaryText)
                        .frame(width: 56, height: 56).background(Color.exPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                }
                ExEyebrow(deviceOnly ? "Offline" : "Free, any time", color: .exPrimaryText)
                Text(deviceOnly ? "Saved on this device" : "Take all your data with you").font(.exH2).foregroundStyle(Color.exTextPrimary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(deviceOnly
                     ? "You're offline, so the export holds everything saved on this iPhone, including changes waiting to sync."
                     : "Every food, weigh-in, workout and target, with its ID, history and units. Ready in seconds.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
                Button { prepare(.everything) } label: {
                    Label(busy == .everything ? "Preparing…" : "Export everything", systemImage: "archivebox")
                }
                .buttonStyle(ExActionStyle()).disabled(busy != nil).accessibilityIdentifier("account.shareExport")
                .accessibilityHint("A zip with a JSON file, a CSV for each kind of data and a spreadsheet")
                Button { prepare(.json) } label: { Text(busy == .json ? "Preparing…" : "JSON file only") }
                    .buttonStyle(ExActionStyle(secondary: true)).disabled(busy != nil).accessibilityIdentifier("export.json")
                if busy != nil {
                    HStack(spacing: ExSpacing.small) {
                        ProgressView().tint(Color.exPrimaryText)
                        Text(deviceOnly ? "Packing what's on this iPhone…" : "Collecting your account…").font(.exCaption)
                            .foregroundStyle(Color.exTextSecondary)
                    }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("export.busy")
                }
                if let fallback {
                    VStack(alignment: .leading, spacing: ExSpacing.small) {
                        Label("This phone's copy only: \(fallback.why)", systemImage: "iphone")
                            .font(.exCaption).foregroundStyle(Color.exWarning).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("export.fallback")
                        Button("Share this phone's copy") {
                            exportFile = fallback.file
                            self.fallback = nil
                        }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("export.shareDevice")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.exCaption).foregroundStyle(Color.exError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityFocused($errorFocused).accessibilityIdentifier("account.exportError")
                }
            }
            ExCard {
                ExSectionHeading("In the zip")
                VStack(spacing: 0) {
                    item("curlybraces", "exerly-export.json", "Everything, as Exerly keeps it. Import it into any Exerly account.")
                    TargetsDivider()
                    item("tablecells", "A CSV for each kind of data", "Every kind of record: foods, weigh-ins, workouts, programs, "
                         + "measurements and the rest, one file each")
                    TargetsDivider()
                    item("doc.richtext", "A spreadsheet", "The same tables as sheets, for Numbers or Excel")
                }
            }
            ExCard {
                ExSectionHeading("How it's written")
                bullet("Stable IDs and revisions, so the same entry is the same row in every export.")
                bullet("Times in UTC with your time zone alongside; dates are your local dates.")
                bullet("Units beside every weight and nutrient. A blank nutrient is unknown, never zero.")
                bullet("Where each entry came from, including the imports that added it.")
                Text(deviceOnly
                     ? "Account details and records kept only on the server are left out until you're online."
                     : "Progress photos stay on this device and are not included.")
                    .font(.exSmall).foregroundStyle(Color.exTextMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Export data").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportFile) { file in
            AccountShareSheet(url: file.url).onDisappear { file.remove() }
        }
        .onDisappear { task?.cancel() }
    }

    private func item(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: ExSpacing.item) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.exPrimaryText)
                    .frame(width: 32, height: 32).background(Color.exPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ExSpacing.small)
        .accessibilityElement(children: .combine)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ExSpacing.small) {
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.exPrimaryText).accessibilityHidden(true)
            Text(text).font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prepare(_ format: Format) {
        guard busy == nil else { return }
        busy = format
        error = nil
        fallback?.file.remove()
        fallback = nil
        task = Task { @MainActor in
            defer { busy = nil }
            do {
                let (data, why) = try await export()
                try Task.checkCancellation()
                let today = LocalDate(Date(), in: .current)
                let file = format == .json
                    ? ExportFiles.File(name: "exerly-export-\(today).json", data: data)
                    : try ExportFiles.bundle(data, date: today)
                let shared = try ExportShareFile(file)
                if let why, !deviceOnly {
                    // Said first; sharing it is the person's choice.
                    fallback = (shared, why)
                    UIAccessibility.post(notification: .announcement, argument: "This phone's copy only: \(why)")
                } else {
                    exportFile = shared
                }
            } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                self.error = AccountScreenError.message(error)
                errorFocused = true
            }
        }
    }

    /// The account's export, or this device's when offline or the account
    /// can't be reached, with why.
    private func export() async throws -> (Data, fallbackReason: String?) {
        if deviceOnly, let device = actions.exportDeviceData { return (try device(), "you're offline.") }
        guard let device = actions.exportDeviceData else { return (try await actions.exportAccount(), nil) }
        let server = Task { @MainActor in try await actions.exportAccount() }
        let timeout = Task { try await Task.sleep(for: Self.serverWait); server.cancel() }
        defer { timeout.cancel() }
        do {
            return (try await server.value, nil)
        } catch {
            if Task.isCancelled { throw error }
            let why = error is CancellationError ? "your account didn't answer within six seconds."
                : "your account couldn't be reached (\(AccountScreenError.message(error)))."
            return (try device(), why)
        }
    }
}

/// A file written for the share sheet, removed once it closes.
struct ExportShareFile: Identifiable {
    let id = UUID()
    let url: URL

    init(_ file: ExportFiles.File, directory: URL = FileManager.default.temporaryDirectory) throws {
        let folder = directory.appendingPathComponent("ExerlyExport-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(file.name)
        do { try file.data.write(to: url, options: [.atomic, .completeFileProtection]) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
