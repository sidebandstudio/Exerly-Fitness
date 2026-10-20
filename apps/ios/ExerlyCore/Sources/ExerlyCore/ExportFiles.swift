import Foundation

/// An Exerly JSON export (`/api/export`, or `AccountExport.merging` on the
/// device) read back for importing into an account. PARITY I14.
public struct ExerlyExportFile: Sendable {
    public struct Document: Sendable, Hashable {
        public var kind: String
        public var id: String
        public var revision: Int
        /// The payload as JSON with sorted keys.
        public var payload: Data
    }

    public var documents: [Document]
    /// Rows of the server's older tables (food log, measurements and so on),
    /// by table. They stay with the server and aren't restored on a phone.
    public var otherTables: [String: Int]
    public var hasAccount: Bool
    /// Made on a device without the server's copy.
    public var offline: Bool
    public var dateRange: ClosedRange<LocalDate>?

    /// Top-level keys that describe the export rather than hold data.
    static let metadata: Set<String> = ["exported_at", "version", "source", "note", "account", "documents", "context", "imports", "format"]

    public init(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["documents"] as? [[String: Any]] else {
            throw DocumentError(message: "This isn't an Exerly export: it has no documents")
        }
        var documents: [Document] = []
        var dates: [LocalDate] = []
        for row in rows where row["deleted_at"] == nil || row["deleted_at"] is NSNull {
            guard let kind = row["kind"] as? String, let id = row["document_id"] as? String,
                  let payload = row["payload"] as? [String: Any] else { continue }
            documents.append(Document(kind: kind, id: id, revision: (row["revision"] as? NSNumber)?.intValue ?? 0,
                                      payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])))
            if let date = (payload["date"] as? String).flatMap(LocalDate.init) ?? (payload["startedAt"] as? String).flatMap({ LocalDate(String($0.prefix(10))) }) {
                dates.append(date)
            }
        }
        self.documents = documents
        otherTables = json.filter { !Self.metadata.contains($0.key) }.compactMapValues { ($0 as? [Any])?.count }
        hasAccount = json["account"] is [String: Any]
        offline = json["source"] as? String == "device"
        if let first = dates.min(), let last = dates.max() { dateRange = first...last }
    }

    static func looksLikeExport(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["documents"] is [Any] && json["exported_at"] != nil
    }

    /// What a kind of document is called in a preview.
    public static func title(_ kind: String) -> String {
        switch kind {
        case "food_entry": "Foods logged"
        case "saved_food": "Foods and recipes"
        case "nutrition_day": "Day statuses and notes"
        case "weight_entry": "Weigh-ins"
        case "nutrition_plan": "Nutrition targets"
        case "hidden_suggestion": "Hidden suggestions"
        case "workout_session": "Workouts"
        case "custom_exercise": "Custom exercises"
        case "program": "Programs"
        case "gym_profile": "Gyms"
        case "proposal": "Coach proposals"
        case "audit_event": "Change history"
        case "custom_metric": "Custom metrics"
        case "metric_entry": "Custom metric values"
        case "experiment": "Experiments"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The export as files people open elsewhere: a CSV for each kind of data, a
/// workbook with the same sheets, and the JSON, zipped together. Made on the
/// device from the JSON export, so it works offline. The CSV columns are the
/// server's `/v1/export` columns (docs/design/022-export-import.md).
public enum ExportFiles {
    public struct File: Sendable, Hashable {
        public var name: String
        public var data: Data
    }

    /// One table per kind of data, header first. Empty kinds are left out.
    public static func tables(_ export: Data) throws -> [(name: String, rows: [[String]])] {
        guard let json = try JSONSerialization.jsonObject(with: export) as? [String: Any] else {
            throw DocumentError(message: "The export isn't a JSON object")
        }
        let documents = ((json["documents"] as? [[String: Any]]) ?? []).filter { $0["deleted_at"] == nil || $0["deleted_at"] is NSNull }
        var tables: [(String, [[String]])] = []
        for table in Self.layout {
            let rows = documents.filter { $0["kind"] as? String == table.kind }
                .compactMap { row -> (order: String, id: String, rows: [[Any?]])? in
                    guard let payload = row["payload"] as? [String: Any] else { return nil }
                    return (table.order(payload), row["document_id"] as? String ?? "", table.rows(payload, row))
                }
                .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
                .flatMap(\.rows)
            guard !rows.isEmpty else { continue }
            tables.append((table.name, [table.header] + rows.map { $0.map(text) }))
        }
        return tables
    }

    /// A CSV file for each table, RFC 4180, CRLF line ends.
    public static func csvFiles(_ export: Data) throws -> [File] {
        try tables(export).map { File(name: "\($0.name).csv", data: Data(csv($0.rows).utf8)) }
    }

    /// Everything in one zip: the JSON, the CSV files, a workbook and a note
    /// saying what each holds.
    public static func bundle(_ export: Data, date: LocalDate) throws -> File {
        let tables = try tables(export)
        var files = [File(name: "exerly-export-\(date).json", data: export)]
        files += tables.map { File(name: "csv/\($0.name).csv", data: Data(csv($0.rows).utf8)) }
        files.append(File(name: "exerly-export-\(date).xlsx", data: workbook(tables)))
        files.append(File(name: "README.txt", data: Data(readme.utf8)))
        return File(name: "exerly-export-\(date).zip", data: zip(files))
    }

    static let readme = """
    Exerly export

    exerly-export-<date>.json holds everything: every document with its ID, revision and payload. It is the file Exerly \
    imports back (Profile, Import & export, Restore an Exerly export).
    csv/ and the .xlsx workbook hold the same data as tables, one per kind:
    food_entries, saved_foods, weigh_ins, days, sets, nutrition_targets, metrics and metric_values.

    - IDs are stable: the same document has the same ID in every export.
    - Instants (logged_at, at, started_at, completed_at, updated_at) are UTC, ISO 8601. Dates are your local dates;
      workouts carry their time zone, and the JSON's "context" gives the account's time zone and units.
    - Nutrient columns name their unit (energy_kcal, sodium_mg). An empty cell means unknown, never zero.
    - Weights and loads have a unit column beside them.
    - Provenance: a food's source and ID, a weigh-in's source, a workout's program, and in the JSON the imports that added data.
    - updated_at is empty for changes this device hasn't synced yet; they are marked "pending_sync" in the JSON.

    © Sideband · https://sideband.studio
    """

    // MARK: Tables

    struct Table: Sendable {
        var name: String
        var kind: String
        var header: [String]
        var rows: @Sendable ([String: Any], [String: Any]) -> [[Any?]]
        var order: @Sendable ([String: Any]) -> String
    }

    static let nutrientHeader = Nutrient.allCases.map { "\($0.rawValue)_\($0.unit.rawValue)" }

    static func nutrients(_ amounts: Any?, scale: Double = 1) -> [Any?] {
        let amounts = amounts as? [String: Any] ?? [:]
        return Nutrient.allCases.map { nutrient -> Any? in (amounts[nutrient.rawValue] as? NSNumber).map { round($0.doubleValue * scale) } }
    }

    static func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    static func mass(_ value: Any?) -> [Any?] {
        guard let mass = value as? [String: Any] else { return [nil, nil] }
        return [mass["value"], mass["unit"]]
    }

    static func string(_ value: Any?) -> String { value as? String ?? "" }
    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func list(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    /// The ID, revision and last change every row starts with.
    static func header(_ d: [String: Any]) -> [Any?] { [d["document_id"], d["revision"], d["updated_at"]] }

    static var layout: [Table] { [foodEntries, savedFoods, weighIns, days, sets, targets, metricValues, metrics] }

    static let foodEntries = Table(
        name: "food_entries", kind: "food_entry",
        header: ["id", "revision", "updated_at", "date", "meal", "logged_at", "food_id", "food_name", "brand", "source", "grams",
                 "serving", "serving_grams", "quantity", "density_g_per_ml", "density_assumed"] + nutrientHeader,
        rows: { p, d in
            let food = object(p["food"]), serving = object(p["serving"]), volume = object(food["volume"])
            let grams = (p["grams"] as? NSNumber)?.doubleValue ?? 0
            let unweighed = (food["unweighed"] as? NSNumber)?.boolValue == true
            var row: [Any?] = header(d)
            row += [p["date"], p["meal"], p["loggedAt"], food["foodID"], food["name"], food["brand"], food["source"]]
            row += [unweighed ? nil : p["grams"], serving["name"], serving["grams"], p["quantity"], volume["density"], volume["assumed"]]
            return [row + nutrients(food["per100g"], scale: grams / 100)]
        },
        order: { "\(string($0["date"])) \(string($0["loggedAt"]))" })

    static let savedFoods = Table(
        name: "saved_foods", kind: "saved_food",
        header: ["id", "revision", "updated_at", "name", "brand", "source", "barcode", "favorite", "archived_at", "servings",
                 "density_g_per_ml", "yield_grams", "serving_count", "ingredients", "preparation"] + nutrientHeader.map { "\($0)_per_100g" },
        rows: { p, d in
            let servings = list(p["servings"]).map { "\(string($0["name"])) = \(text($0["grams"])) g" }.joined(separator: "; ")
            let ingredients = list(p["ingredients"]).map { ingredient -> String in
                let grams: Double? = (ingredient["grams"] as? NSNumber).map { round($0.doubleValue) }
                return "\(string(object(ingredient["food"])["name"])) = \(text(grams)) g"
            }.joined(separator: "; ")
            var row: [Any?] = header(d)
            row += [p["name"], p["brand"], p["source"], p["barcode"], p["favorite"], p["archivedAt"], servings]
            row += [object(p["volume"])["density"], p["yieldGrams"], p["servingCount"], ingredients, p["preparation"]]
            return [row + nutrients(p["per100g"])]
        },
        order: { string($0["name"]).lowercased() })

    static let weighIns = Table(
        name: "weigh_ins", kind: "weight_entry",
        header: ["id", "revision", "updated_at", "at", "date", "weight", "unit", "body_fat_percent", "source"],
        rows: { p, d in
            let row: [Any?] = header(d) + [p["at"], p["date"]] + mass(p["weight"]) + [p["bodyFat"], p["source"]]
            return [row]
        },
        order: { string($0["at"]) })

    static let days = Table(
        name: "days", kind: "nutrition_day",
        header: ["date", "revision", "updated_at", "status", "notes", "tags"],
        rows: { p, d in
            let tags = (p["tags"] as? [String] ?? []).joined(separator: "; ")
            let row: [Any?] = [p["date"], d["revision"], d["updated_at"], p["status"], p["notes"], tags]
            return [row]
        },
        order: { string($0["date"]) })

    static let sets = Table(
        name: "sets", kind: "workout_session",
        header: ["session_id", "revision", "updated_at", "session", "started_at", "ended_at", "time_zone", "exercise_position",
                 "exercise_id", "superset_id", "set_position", "set_id", "kind", "side", "effort", "reps", "load", "load_unit",
                 "duration_s", "distance_m", "rir", "completed_at", "bodyweight", "bodyweight_unit", "program_id", "program_day_id",
                 "program_cycle"],
        rows: { p, d in
            let program = object(p["program"])
            let session: [Any?] = header(d) + [p["name"], p["startedAt"], p["endedAt"], p["timeZoneID"]]
            let tail: [Any?] = mass(p["bodyweight"]) + [program["programID"], program["dayID"], program["cycle"]]
            var rows: [[Any?]] = []
            for (e, exercise) in list(p["exercises"]).enumerated() {
                for (s, set) in list(exercise["sets"]).enumerated() {
                    for (f, effort) in list(set["efforts"]).enumerated() {
                        var row = session
                        row += [e + 1, exercise["exerciseID"], exercise["supersetID"], s + 1, set["id"], set["kind"], set["side"], f + 1]
                        row += [effort["reps"]] + mass(effort["load"])
                        row += [effort["duration"], effort["distance"], set["rir"], set["completedAt"]]
                        rows.append(row + tail)
                    }
                }
            }
            return rows
        },
        order: { string($0["startedAt"]) })

    static let targets = Table(
        name: "nutrition_targets", kind: "nutrition_plan",
        header: ["id", "revision", "updated_at", "start_date", "created_at", "mode", "goal", "weekday", "energy_kcal", "protein_g",
                 "carbohydrate_g", "fat_g"],
        rows: { p, d in
            let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let plan: [Any?] = header(d) + [p["startDate"], p["createdAt"], p["mode"], object(p["goal"])["direction"]]
            return list(p["targets"]).enumerated().map { day, target in
                plan + [day < 7 ? weekdays[day] : "\(day + 1)", target["energy"], target["protein"], target["carbohydrate"], target["fat"]]
            }
        },
        order: { "\(string($0["startDate"])) \(string($0["createdAt"]))" })

    static let metricValues = Table(
        name: "metric_values", kind: "metric_entry",
        header: ["id", "revision", "updated_at", "metric_id", "date", "value"],
        rows: { p, d in [header(d) + [p["metricID"], p["date"], p["value"]]] },
        order: { "\(string($0["metricID"])) \(string($0["date"]))" })

    static let metrics = Table(
        name: "metrics", kind: "custom_metric",
        header: ["id", "revision", "updated_at", "name", "unit", "kind", "minimum", "maximum", "archived"],
        rows: { p, d in [header(d) + [p["name"], p["unit"], p["kind"], p["minimum"], p["maximum"], p["archived"]]] },
        order: { string($0["name"]).lowercased() })

    // MARK: CSV

    /// A cell's text: numbers as JavaScript writes them, objects as JSON,
    /// nothing for null.
    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return "\(double)"
        case let value?:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
               let json = String(bytes: data, encoding: .utf8) {
                return json
            }
            return "\(value)"
        }
    }

    /// Text a spreadsheet would run as a formula gets a leading apostrophe.
    static func cell(_ text: String) -> String {
        var text = text
        if let first = text.first, "=+-@\t\r".contains(first), Double(text) == nil { text = "'" + text }
        return text.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" }) ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Workbook

    /// An .xlsx with a sheet per table: numbers as numbers, the rest as inline
    /// text, the header row bold and frozen.
    static func workbook(_ tables: [(name: String, rows: [[String]])]) -> Data {
        func escape(_ text: String) -> String {
            var escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            escaped.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }
            return escaped
        }
        func column(_ index: Int) -> String {
            var index = index + 1, name = ""
            while index > 0 {
                name = String(UnicodeScalar(UInt8(65 + (index - 1) % 26))) + name
                index = (index - 1) / 26
            }
            return name
        }
        var files: [File] = []
        var sheets = "", relations = "", overrides = ""
        for (number, table) in tables.enumerated() {
            let n = number + 1
            var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
            xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetData>"#
            for (r, row) in table.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let reference = "\(column(c))\(r + 1)"
                    if r > 0, let number = Double(value), number.isFinite, !value.hasPrefix("+"), !(value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0.")) {
                        xml += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                    } else {
                        xml += "<c r=\"\(reference)\" t=\"inlineStr\"\(r == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            files.append(File(name: "xl/worksheets/sheet\(n).xml", data: Data(xml.utf8)))
            sheets += "<sheet name=\"\(escape(String(table.name.prefix(31))))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            relations += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        let stylesID = tables.count + 1
        relations += "<Relationship Id=\"rId\(stylesID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        files.insert(contentsOf: [
            File(name: "[Content_Types].xml", data: Data((head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"# + overrides + "</Types>").utf8)),
            File(name: "_rels/.rels", data: Data((head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#).utf8)),
            File(name: "xl/workbook.xml", data: Data((head + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# + sheets + "</sheets></workbook>").utf8)),
            File(name: "xl/_rels/workbook.xml.rels", data: Data((head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + relations + "</Relationships>").utf8)),
            File(name: "xl/styles.xml", data: Data((head + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf fontId="0"/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>"#).utf8)),
        ], at: 0)
        return zip(files)
    }

    // MARK: Zip

    /// A zip archive with each file stored uncompressed.
    static func zip(_ files: [File]) -> Data {
        var archive = Data(), directory = Data()
        func le16(_ value: Int, _ data: inout Data) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
        func le32(_ value: UInt32, _ data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        // 2026-01-01 00:00 in MS-DOS form, so the same export zips to the same bytes.
        let time = 0, date = ((2026 - 1980) << 9) | (1 << 5) | 1
        for file in files {
            let name = Data(file.name.utf8), crc = crc32(file.data), offset = UInt32(archive.count)
            le32(0x0403_4B50, &archive); le16(20, &archive); le16(0x0800, &archive); le16(0, &archive); le16(time, &archive); le16(date, &archive)
            le32(crc, &archive); le32(UInt32(file.data.count), &archive); le32(UInt32(file.data.count), &archive)
            le16(name.count, &archive); le16(0, &archive)
            archive += name
            archive += file.data
            le32(0x0201_4B50, &directory); le16(20, &directory); le16(20, &directory); le16(0x0800, &directory); le16(0, &directory)
            le16(time, &directory); le16(date, &directory); le32(crc, &directory); le32(UInt32(file.data.count), &directory)
            le32(UInt32(file.data.count), &directory); le16(name.count, &directory); le16(0, &directory); le16(0, &directory)
            le16(0, &directory); le16(0, &directory); le32(0, &directory); le32(offset, &directory)
            directory += name
        }
        let start = UInt32(archive.count)
        archive += directory
        le32(0x0605_4B50, &archive); le16(0, &archive); le16(0, &archive); le16(files.count, &archive); le16(files.count, &archive)
        le32(UInt32(directory.count), &archive); le32(start, &archive); le16(0, &archive)
        return archive
    }

    static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
