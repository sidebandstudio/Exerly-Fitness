import Foundation
import Observation

/// Where imported records came from: the app, the files, when, and which
/// documents. Unlike `ImportRecord`, which keeps what Undo needs on the device
/// that imported, provenance is a document: it syncs, it's in every export,
/// and it comes along when an export is restored into another account.
/// An import of thousands of documents is split into parts, so each stays
/// well under the server's size for one document.
public struct ImportProvenance: Sendable, Codable, Hashable, Identifiable {
    /// "<import ID>.<part>", as the server requires, the payload's ID is the document's.
    public var id: String
    /// The import's ID, as in its `ImportRecord`.
    public var importID: UUID
    public var part: Int
    public var parts: Int
    public var source: ImportSource
    public var files: [String]
    public var importedAt: Date
    public var timeZoneID: String
    public var lines: [ImportLine]
    /// The documents this part covers, as "kind/id".
    public var documents: [String]

    /// Documents a part lists: about 150 kB, under the server's 256 kB.
    static let partSize = 3000

    /// The parts for an import that saved `documents`.
    static func parts(for record: ImportRecord, documents: [String]) -> [ImportProvenance] {
        let chunks = stride(from: 0, to: max(documents.count, 1), by: partSize).map { Array(documents[$0..<min($0 + partSize, documents.count)]) }
        return chunks.enumerated().map { index, chunk in
            ImportProvenance(id: "\(record.id.uuidString).\(index)", importID: record.id, part: index, parts: chunks.count,
                             source: record.source, files: record.files, importedAt: record.importedAt, timeZoneID: record.timeZoneID,
                             lines: record.lines, documents: chunk)
        }
    }
}

/// The account's import provenance, kept as `import_provenance` documents.
@MainActor
@Observable
public final class ProvenanceStore {
    static let kind = "import_provenance"

    /// Every part, the latest import first.
    public private(set) var provenance: [ImportProvenance] = []

    @ObservationIgnored private let persistence: DocumentPersistence

    public init(persistence: DocumentPersistence) throws {
        self.persistence = persistence
        provenance = try persistence.loadDocuments(kind: Self.kind)
            .map { try ExerlyJSON.decoder.decode(ImportProvenance.self, from: $0) }.sorted(by: Self.order)
    }

    static func order(_ a: ImportProvenance, _ b: ImportProvenance) -> Bool {
        (a.importedAt, a.importID.uuidString, -a.part) > (b.importedAt, b.importID.uuidString, -b.part)
    }

    /// Where a document came from, if an import saved it.
    public func origin(kind: String, id: String) -> ImportProvenance? {
        provenance.first { $0.documents.contains("\(kind)/\(id)") }
    }
}

extension ProvenanceStore: DocumentHost {
    public var documentKinds: [String] { [Self.kind] }

    public func documentIDs(kind: String) -> [String] { provenance.map(\.id) }

    public func payload(kind: String, id: String) throws -> Data? {
        try provenance.first { $0.id == id }.map(ExerlyJSON.canonical)
    }

    public func canonicalize(kind: String, payload: Data) throws -> Data {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        return try ExerlyJSON.canonical(ExerlyJSON.decoder.decode(ImportProvenance.self, from: payload))
    }

    public func validate(kind: String, id: String, payload: Data) throws {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        let provenance = try ExerlyJSON.decoder.decode(ImportProvenance.self, from: payload)
        guard provenance.id == id, id == "\(provenance.importID.uuidString).\(provenance.part)" else {
            throw DocumentError(message: "The provenance ID doesn't match")
        }
        guard (0..<provenance.parts).contains(provenance.part) else { throw DocumentError(message: "The provenance part is out of range") }
    }

    /// Provenance never changes once written; the local copy stands.
    public func merge(kind: String, base: Data?, local: Data, remote: Data) throws -> Data { local }

    public func prepareWrite(kind: String, id: String, payload: Data?) throws -> () -> Void {
        guard kind == Self.kind else { throw DocumentError(message: "Unknown kind \(kind)") }
        guard let payload else {
            try persistence.deleteDocument(kind: kind, id: id)
            return { [self] in provenance.removeAll { $0.id == id } }
        }
        let part = try ExerlyJSON.decoder.decode(ImportProvenance.self, from: payload)
        try persistence.saveDocument(kind: kind, id: id, payload: ExerlyJSON.canonical(part))
        return { [self] in provenance = (provenance.filter { $0.id != id } + [part]).sorted(by: Self.order) }
    }
}
