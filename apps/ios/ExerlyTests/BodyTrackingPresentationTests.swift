import ExerlyCore
import UIKit
import XCTest
@testable import Exerly

/// Measurements as the screens show them, the goal's standing words, and
/// progress photos kept per account on the device.
@MainActor
final class BodyTrackingPresentationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "photos-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func record(_ type: String, _ value: Double, unit: String = "cm", date: String = "2026-10-01",
                        id: String = UUID().uuidString) -> BodyMeasurementDTO {
        BodyMeasurementDTO(id: id, client_id: id, type: type, value: value, unit: unit, entry_date: date, revision: 1)
    }

    func testRecordsBecomeReadingsInCentimetresAndSkipUnknownSites() throws {
        let records = MeasurementRecords([
            record("left_bicep", 33.5), record("waist", 34, unit: "in", date: "2026-10-05"), record("weight", 80),
            record("calves", 38), record("body_fat", 18.5, unit: "%"), record("waist", 88, date: "bad"),
        ])
        XCTAssertEqual(records.readings.count, 4, "An unknown type and a bad date are left out")
        let waist = try XCTUnwrap(records.readings.first { $0.site == .waist })
        XCTAssertEqual(waist.value, 86.36, accuracy: 1e-9, "A record kept in inches converts")
        XCTAssertEqual(records.sites, [.waist, .leftBicep, .calves, .bodyFat], "Entry order, older sites after the limbs")
        XCTAssertEqual(records.records[waist.id]?.type, "waist")
    }

    func testMeasurementsReadInThePersonsUnitWithATrueMinus() {
        XCTAssertEqual(MeasurementFormat.value(86.36, .waist, .inches), "34.0 in")
        XCTAssertEqual(MeasurementFormat.value(86.36, .waist, .centimetres), "86.4 cm")
        XCTAssertEqual(MeasurementFormat.value(18.25, .bodyFat, .inches), "18.3 %")
        XCTAssertEqual(MeasurementFormat.change(-1.27, .waist, .inches), "−0.5 in")
        XCTAssertEqual(MeasurementFormat.change(0.01, .waist, .inches), "No change")
        XCTAssertEqual(MeasurementFormat.spoken(33.528, .leftBicep, .inches), "13.2 inches")
        XCTAssertEqual(MeasurementFormat.spokenChange(-1.27, .waist, .inches), "down 0.5 inches")
        XCTAssertEqual(MeasurementFormat.spokenChange(1, .bodyFat, .centimetres), "up 1.0 percent")
    }

    func testTheGoalsStandingSaysWhichWayAndHowFar() {
        func words(_ offset: Double, _ direction: NutritionGoal.Direction = .lose) -> String {
            let standing = WeightGoal.standing(trend: 80 + offset, trendError: 0.1, planned: 80, direction: direction, tolerance: 0.4)
            return BodyGoalCard.status(standing, direction: direction, unit: .pounds).0
        }
        XCTAssertEqual(words(0.2), "On track")
        XCTAssertEqual(words(-0.6804), "Ahead by 1.5 lb")
        XCTAssertEqual(words(0.4536), "Behind by 1.0 lb")
        XCTAssertEqual(words(0.9072, .maintain), "Up 2.0 lb")
        XCTAssertEqual(words(-0.9072, .gain), "Behind by 2.0 lb")
    }

    private func photoData(width: CGFloat = 60, height: CGFloat = 80) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    func testPhotosAreKeptByDateAndPosePerAccountAndSurviveAReload() throws {
        let store = ProgressPhotoStore(accountID: "account-a", root: root)
        let monday = try XCTUnwrap(LocalDate("2026-10-05")), friday = try XCTUnwrap(LocalDate("2026-10-09"))
        try store.add(photoData(), date: monday, pose: .side)
        let front = try store.add(photoData(), date: monday, pose: .front)
        try store.add(photoData(), date: friday, pose: .back)
        XCTAssertEqual(store.dates, [friday, monday], "Newest date first")
        XCTAssertEqual(store.photos(on: monday).map(\.pose), [.front, .side])
        XCTAssertEqual(store.photo(on: monday, pose: .front), front)
        XCTAssertNotNil(store.image(front))
        XCTAssertNotNil(store.thumbnail(front))

        let reloaded = ProgressPhotoStore(accountID: "account-a", root: root)
        XCTAssertEqual(reloaded.photos, store.photos, "Saved on the device")
        XCTAssertTrue(ProgressPhotoStore(accountID: "account-b", root: root).photos.isEmpty, "Another account sees none")

        try store.setPose(.back, for: front)
        XCTAssertEqual(store.photos(on: monday).map(\.pose), [.side, .back])
        try store.delete(store.photos(on: friday)[0])
        XCTAssertEqual(store.dates, [monday])

        try ProgressPhotoStore.removeAll(accountID: "account-a", root: root)
        XCTAssertTrue(ProgressPhotoStore(accountID: "account-a", root: root).photos.isEmpty, "A deleted account's photos go")
        XCTAssertNoThrow(try ProgressPhotoStore.removeAll(accountID: "never-had-any", root: root))
    }

    func testDeletingAPhotoRemovesItsFile() throws {
        let store = ProgressPhotoStore(accountID: "account-a", root: root)
        let photo = try store.add(photoData(), date: try XCTUnwrap(LocalDate("2026-10-05")), pose: .front)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(photo).path))
        try store.delete(photo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(photo).path))
        XCTAssertTrue(store.photos.isEmpty)
    }

    func testLargePhotosAreScaledDownAndUnreadableOnesRefused() throws {
        let jpeg = try XCTUnwrap(ProgressPhotoStore.jpeg(photoData(width: 4000, height: 3000)))
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(max(image.size.width * image.scale, image.size.height * image.scale), ProgressPhotoStore.maximumPixels)
        XCTAssertNil(ProgressPhotoStore.jpeg(Data("not an image".utf8)))
        let store = ProgressPhotoStore(accountID: "account-a", root: root)
        XCTAssertThrowsError(try store.add(Data("nope".utf8), date: try XCTUnwrap(LocalDate("2026-10-05")), pose: .front))
        XCTAssertTrue(store.photos.isEmpty)
    }
}
