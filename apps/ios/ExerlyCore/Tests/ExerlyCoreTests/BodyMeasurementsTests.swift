import Foundation
import Testing
@testable import ExerlyCore

@Suite struct BodyMeasurementsTests {
    let day = LocalDate("2026-09-07")!

    @Test func everySiteHasANameASideAndAnAPIType() {
        #expect(BodySite.entry.count == 19)
        #expect(BodySite.entry.first == .neck && BodySite.entry.last == .bodyFat)
        #expect(!BodySite.entry.contains { $0.isLegacy })
        #expect(BodySite.leftBicep.rawValue == "left_bicep" && BodySite.leftBicep.name == "Left bicep")
        #expect(BodySite.rightAnkle.name == "Right ankle" && BodySite.rightAnkle.limb == "Ankle" && BodySite.rightAnkle.side == .right)
        #expect(BodySite.waist.name == "Waist" && BodySite.waist.limb == "Waist" && BodySite.waist.side == nil)
        #expect(BodySite.bodyFat.name == "Body fat" && !BodySite.bodyFat.isLength)
        #expect(BodySite(rawValue: "calves")?.isLegacy == true)
        // Each side's pair sits next to it, left first.
        for (index, site) in BodySite.entry.enumerated() where site.side == .left {
            #expect(BodySite.entry[index + 1].limb == site.limb && BodySite.entry[index + 1].side == .right)
        }
    }

    @Test func lengthsShowInThePersonsUnitAndBodyFatStaysAPercentage() {
        #expect(LengthUnit(.pounds) == .inches && LengthUnit(.kilograms) == .centimetres)
        #expect(BodyMeasurements.display(86.36, site: .waist, unit: .inches) == 34)
        #expect(BodyMeasurements.display(86.36, site: .waist, unit: .centimetres) == 86.4)
        #expect(BodyMeasurements.display(18.25, site: .bodyFat, unit: .inches) == 18.3)
        #expect(abs(BodyMeasurements.stored(34, site: .waist, unit: .inches) - 86.36) < 1e-9)
        #expect(BodyMeasurements.stored(18, site: .bodyFat, unit: .inches) == 18)
    }

    @Test func theSheetSavesOnlyWhatChanged() {
        let prefilled: [BodySite: Double] = [.waist: 34, .hips: 40.5, .leftBicep: 13.2]
        let entered: [BodySite: Double] = [.waist: 33.5, .hips: 40.5, .leftBicep: 13.21, .rightBicep: 13.4]
        let changes = BodyMeasurements.changes(entered: entered, prefilled: prefilled, unit: .inches)
        #expect(Set(changes.keys) == [.waist, .rightBicep], "Untouched and same-as-shown values aren't saved")
        #expect(abs((changes[.waist] ?? 0) - 33.5 * 2.54) < 1e-9)
        #expect(abs((changes[.rightBicep] ?? 0) - 13.4 * 2.54) < 1e-9)
        #expect(BodyMeasurements.changes(entered: [.bodyFat: 17], prefilled: [.bodyFat: 18], unit: .inches) == [.bodyFat: 17])
        #expect(BodyMeasurements.changes(entered: [:], prefilled: prefilled, unit: .inches).isEmpty)
    }

    @Test func historyLatestAndChangeFollowTheDates() {
        let readings = [
            BodyMeasurementReading(id: "c", site: .waist, date: day.adding(days: 14), value: 85),
            BodyMeasurementReading(id: "a", site: .waist, date: day, value: 88),
            BodyMeasurementReading(id: "b", site: .waist, date: day.adding(days: 7), value: 86.5),
            BodyMeasurementReading(id: "d", site: .hips, date: day, value: 100),
        ]
        #expect(BodyMeasurements.history(readings, site: .waist).map(\.id) == ["a", "b", "c"])
        #expect(BodyMeasurements.latest(readings)[.waist]?.id == "c")
        #expect(BodyMeasurements.latest(readings)[.hips]?.id == "d")
        #expect(BodyMeasurements.change(readings, site: .waist) == -1.5)
        #expect(BodyMeasurements.change(readings, site: .hips) == nil)
    }

    @Test func implausibleValuesAreExplainedInThePersonsUnit() {
        #expect(BodyMeasurements.problem(86, site: .waist, unit: .inches) == nil)
        #expect(BodyMeasurements.problem(2, site: .leftWrist, unit: .inches) == "Left wrist must be 2 to 118.1 in")
        #expect(BodyMeasurements.problem(400, site: .waist, unit: .centimetres) == "Waist must be 5 to 300 cm")
        #expect(BodyMeasurements.problem(80, site: .bodyFat, unit: .inches) == "Body fat must be 2 to 70 %")
        #expect(BodyMeasurements.problem(.nan, site: .hips, unit: .centimetres) != nil)
    }
}
