import ExerlyCore
import SwiftUI
import XCTest
@testable import Exerly

/// Opt-in captures of the Health import preview's two choices, which a UI
/// test can't reach: Health can't be revoked or Exerly reinstalled there.
/// The previews are the model's own, from a stub Health, drawn at the small
/// phone's size in a window, as on the device.
@MainActor
final class HealthPreviewCaptureTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!

    func testNoLongerInHealthAndAdoptPreviewsCapture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EXERLY_DESIGN_CAPTURE"] == "1", let directory = environment["EXERLY_SCREEN_DIR"], !directory.isEmpty else {
            throw XCTSkip("Opt-in visual review of Health's preview choices")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TrainingWorkspace(accountID: "capture", root: root)
        let client = FakeHistoryClient()
        let now = Date()
        client.foods = (1...6).map { day in
            HealthFoodReading(id: UUID(), at: now.addingTimeInterval(Double(-day) * 86400), name: "Synthetic oats",
                              nutrients: NutrientAmounts([.energy: 380]), source: "com.example.tracker", sourceName: "Tracker")
        }
        func model(_ install: String, on space: TrainingWorkspace? = nil, health: FakeHistoryClient? = nil) -> HealthHistoryModel {
            HealthHistoryModel(accountID: "capture", timeZone: zone, client: health ?? client, namespace: "capture",
                               defaults: UserDefaults(suiteName: "capture-\(UUID().uuidString)")!, install: install,
                               workspace: { space ?? workspace }, isCurrent: { _ in true }, enableWeights: { _ in true },
                               activities: { FakeActivityStore(today: LocalDate(now, in: self.zone)) })
        }
        let phone = model("this-phone")
        await phone.begin(.foods)
        await phone.confirm()
        // Health stops returning two, with no deletion, as when reading is turned off in Health.
        client.foods.removeLast(2)
        await phone.checkEverythingAgain(.foods)
        let missing = try XCTUnwrap(phone.pending)
        XCTAssertEqual(missing.preview.missing, 2)
        // Exerly reinstalled: the same imports, now another install's.
        let reinstalled = model("reinstalled")
        await reinstalled.checkEverythingAgain(.foods)
        let adopt = try XCTUnwrap(reinstalled.pending)
        XCTAssertEqual(adopt.preview.adoptable, 4)
        // Changed while its preview was open: shown again as importing would go now.
        let changedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: changedRoot) }
        let changing = try TrainingWorkspace(accountID: "capture", root: changedRoot), health = FakeHistoryClient()
        let oats = client.foods[0]
        health.foods = [oats]
        let editing = model("this-phone", on: changing, health: health)
        await editing.begin(.foods)
        await editing.confirm()
        health.foods.append(HealthFoodReading(id: UUID(), at: oats.at.addingTimeInterval(600), name: "Synthetic oats",
                                              nutrients: NutrientAmounts([.energy: 410]), source: "com.apple.health.capture",
                                              sourceName: "Apple Watch"))
        await editing.begin(.foods)
        let entry = try XCTUnwrap(changing.nutrition.entries.first)
        try changing.nutrition.saveEntry(entry.editingNutrients(NutrientAmounts([.energy: 450])))
        await editing.confirm()
        let revised = try XCTUnwrap(editing.pending)
        XCTAssertNotNil(revised.note)

        let style = environment["EXERLY_TEST_APPEARANCE"] == "light" ? UIUserInterfaceStyle.light : .dark
        let largest = environment["EXERLY_TEST_LARGEST_TYPE"] == "1"
        for (name, pending) in [("health-preview-no-longer-in-health", missing), ("health-preview-adopt", adopt),
                                ("health-preview-revised", revised)] {
            let sheet = HealthImportPreviewSheet(pending: pending, onImport: { _ in }, onCancel: {})
                .environment(\.dynamicTypeSize, largest ? .accessibility5 : .large)
            let data = try render(sheet, style: style, largest: largest)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// The view in a window the small phone's size, drawn once laid out.
    private func render(_ view: some View, style: UIUserInterfaceStyle, largest: Bool) throws -> Data {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view)
        host.traitOverrides.preferredContentSizeCategory = largest ? .accessibilityExtraExtraExtraLarge : .large
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return try XCTUnwrap(image.pngData())
    }
}
