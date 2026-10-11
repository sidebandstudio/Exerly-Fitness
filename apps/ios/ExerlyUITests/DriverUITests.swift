import XCTest

/// Hands the running app to someone outside the code, such as a usability
/// tester, through files. Each line appended to `commands.jsonl` is one
/// action; after it, `step-N.png` shows the screen and `step-N.txt` lists
/// what's on it the way a screen reader would, without code names.
///
/// Actions: {"action":"tap","label":"Search"} (add "index" for duplicates),
/// {"action":"longPress","label":"..."}, {"action":"tapAt","x":100,"y":200},
/// {"action":"type","text":"banana"}, {"action":"swipe","direction":"up"},
/// {"action":"drag","from":[300,500],"to":[300,420]} (a finger's drag, such
/// as turning one wheel of a time picker; add "slow":true to hold at the end,
/// so a wheel stops where the finger does), {"action":"wait","seconds":2},
/// {"action":"done"}.
/// Run with apps/ios/scripts/drive.sh.
final class DriverUITests: ExerlyUITestCase {
    func testDrive() async throws {
        guard let path = ProcessInfo.processInfo.environment["EXERLY_DRIVER_DIR"], !path.isEmpty else {
            throw XCTSkip("Opt-in remote control for usability runs")
        }
        continueAfterFailure = true
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app: XCUIApplication
        if ProcessInfo.processInfo.environment["EXERLY_DRIVER_NEW_USER"] == "1" {
            try await control([:])
            app = launch(resetSession: true)
        } else {
            app = try await signedInWithRealisticHistory(prefix: "driver")
        }
        var step = 0, taps = 0, handled = 0
        func report(_ result: String) {
            let shot = app.screenshot()
            try? shot.pngRepresentation.write(to: directory.appendingPathComponent("step-\(step).png"))
            let text = "\(result)\nTaps so far: \(taps)\n\nOn screen:\n" + describe(app)
            try? text.write(to: directory.appendingPathComponent("step-\(step).txt"), atomically: true, encoding: .utf8)
            try? String(step).write(to: directory.appendingPathComponent("latest"), atomically: true, encoding: .utf8)
        }
        report("Ready. The app is open.")
        let commands = directory.appendingPathComponent("commands.jsonl")
        let deadline = Date().addingTimeInterval(90 * 60)
        while Date() < deadline {
            let lines = ((try? String(contentsOf: commands, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count > handled else { try await Task.sleep(for: .milliseconds(300)); continue }
            for line in lines[handled...] {
                handled += 1
                step += 1
                guard let data = line.data(using: .utf8),
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let action = command["action"] as? String else { report("Could not read: \(line)"); continue }
                if action == "done" { report("Finished after \(taps) taps."); return }
                report(perform(action, command, in: app, taps: &taps))
            }
        }
        report("Timed out after 90 minutes.")
    }

    private func perform(_ action: String, _ command: [String: Any], in app: XCUIApplication, taps: inout Int) -> String {
        switch action {
        case "tap", "longPress":
            guard let label = command["label"] as? String else { return "tap needs a label" }
            let matches = elements(labelled: label, in: app)
            let index = command["index"] as? Int ?? 0
            guard matches.indices.contains(index) else {
                return "Nothing on screen is labelled “\(label)”." + (matches.isEmpty ? "" : " \(matches.count) matches; use an index below \(matches.count).")
            }
            if action == "tap" { matches[index].tap() } else { matches[index].press(forDuration: 1.0) }
            taps += 1
            Thread.sleep(forTimeInterval: 0.8)
            return "\(action == "tap" ? "Tapped" : "Long-pressed") “\(label)”."
        case "tapAt":
            guard let x = command["x"] as? Double, let y = command["y"] as? Double else { return "tapAt needs x and y in points" }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
            taps += 1
            Thread.sleep(forTimeInterval: 0.8)
            return "Tapped at \(Int(x)), \(Int(y))."
        case "type":
            guard let text = command["text"] as? String else { return "type needs text" }
            app.typeText(text)
            Thread.sleep(forTimeInterval: 0.6)
            return "Typed “\(text)”."
        case "swipe":
            switch command["direction"] as? String {
            case "up": app.swipeUp()
            case "down": app.swipeDown()
            case "left": app.swipeLeft()
            case "right": app.swipeRight()
            default: return "swipe needs a direction: up, down, left or right"
            }
            Thread.sleep(forTimeInterval: 0.6)
            return "Swiped \(command["direction"] as? String ?? "")."
        case "drag":
            guard let from = command["from"] as? [Double], let to = command["to"] as? [Double], from.count == 2, to.count == 2 else {
                return "drag needs from and to as [x, y] in points"
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: from[0], dy: from[1])), end = origin.withOffset(CGVector(dx: to[0], dy: to[1]))
            if command["slow"] as? Bool == true {
                start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
            } else {
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            Thread.sleep(forTimeInterval: 0.8)
            return "Dragged from \(Int(from[0])), \(Int(from[1])) to \(Int(to[0])), \(Int(to[1]))."
        case "wait":
            Thread.sleep(forTimeInterval: min(command["seconds"] as? Double ?? 1, 10))
            return "Waited."
        default:
            return "Unknown action \(action)."
        }
    }

    /// Hittable elements whose label is exactly this, or else contains it.
    private func elements(labelled label: String, in app: XCUIApplication) -> [XCUIElement] {
        let any = app.descendants(matching: .any)
        for predicate in [NSPredicate(format: "label == %@", label), NSPredicate(format: "label CONTAINS[c] %@", label)] {
            let found = any.matching(predicate).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            if !found.isEmpty { return found }
        }
        return []
    }

    /// One line per visible, labelled element: its kind, label, value and
    /// position in points. Code identifiers are left out.
    private func describe(_ app: XCUIApplication) -> String {
        let pattern = try! NSRegularExpression(pattern: #"^\s*(\w[\w ]*?), 0x[0-9a-f]+, \{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}(.*)$"#)
        let screen = app.frame
        var lines: [String] = []
        for raw in frontLayer(app.debugDescription.split(separator: "\n").map(String.init)) {
            let range = NSRange(raw.startIndex..., in: raw)
            guard let match = pattern.firstMatch(in: raw, range: range) else { continue }
            func group(_ index: Int) -> String { Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? "" }
            let rest = group(6)
            guard let label = field("label", in: rest), !label.isEmpty else { continue }
            let frame = CGRect(x: Double(group(2)) ?? 0, y: Double(group(3)) ?? 0, width: Double(group(4)) ?? 0, height: Double(group(5)) ?? 0)
            guard frame.width > 0, frame.height > 0, screen.intersects(frame) else { continue }
            var line = "\(group(1)) “\(label)”"
            if let value = field("value", in: rest), !value.isEmpty { line += " = \(value)" }
            line += " at (\(Int(frame.midX)), \(Int(frame.midY)))"
            if rest.contains("Disabled") { line += ", disabled" }
            if rest.contains("Selected") { line += ", selected" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The tree without what VoiceOver can't reach. The main window's children
    /// are layers: the tabs, then each sheet, menu or popover over them, and
    /// only the top one is read. Run 6's dumps listed every layer, the top
    /// one last, so sheets looked unlabelled. Other windows, such as the
    /// keyboard's, stay.
    private func frontLayer(_ lines: [String]) -> [String] {
        func depth(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        guard let window = lines.firstIndex(where: { $0.contains("Window (Main)") }) else { return lines }
        let level = depth(lines[window])
        let end = lines[(window + 1)...].firstIndex { depth($0) <= level } ?? lines.endIndex
        let layers = (window + 1..<end).filter { depth(lines[$0]) == level + 2 }
        guard layers.count > 1, let top = layers.last else { return lines }
        return Array(lines[..<(window + 1)] + lines[top...])
    }

    /// Run 6 read the Log food sheet, menus and the workout summary as
    /// unlabelled: they were all in the dump, after the screens under them.
    func testTheDumpListsOnlyTheLayerOnTop() async throws {
        let app = try await signedInWithWeek(prefix: "driver-dump")
        XCTAssertTrue(todayScreen(app).waitForExistence(timeout: 20))
        let today = describe(app)
        XCTAssertTrue(today.contains("Button “Train”"), "No sheet: the screen and its tabs\n\(today)")

        tap(app.buttons["nutrition.addFood"], in: app)
        let food = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nutrition.food.")).firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 10))
        dismissKeyboard(app)
        let picker = describe(app)
        XCTAssertTrue(picker.contains("“Add food”"), picker)
        XCTAssertFalse(picker.contains("Button “Train”"), "The tabs are under the sheet\n\(picker)")

        tap(food, in: app)
        XCTAssertTrue(app.buttons["nutrition.saveEntry"].waitForExistence(timeout: 10))
        let sheet = describe(app)
        XCTAssertTrue(sheet.contains("StaticText “Log food”"), sheet)
        XCTAssertTrue(sheet.contains("Button “Log to "), sheet)
        XCTAssertFalse(sheet.contains("“Add food”"), "Add food is under it\n\(sheet)")
    }

    /// A quoted field such as label: 'Today's workout', which ends at a
    /// quote followed by a comma or the end of the line.
    private func field(_ name: String, in text: String) -> String? {
        guard let match = text.range(of: "\(name): '(.*?)'(?=,|$)", options: .regularExpression) else { return nil }
        return String(text[match].dropFirst(name.count + 3).dropLast())
    }
}
