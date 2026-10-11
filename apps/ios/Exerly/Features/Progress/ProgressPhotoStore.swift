import ExerlyCore
import Foundation
import ImageIO
import UIKit

/// Progress photos on this device only, one folder per account under
/// Application Support: a JPEG per photo and an index of their dates and
/// poses. Nothing here is uploaded; sharing is always the person's choice.
/// A date may hold several photos of a pose; screens show the newest.
@MainActor
final class ProgressPhotoStore: ObservableObject {
    enum Pose: String, Codable, CaseIterable, Identifiable, Sendable {
        case front, side, back
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    struct Photo: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        var date: LocalDate
        var pose: Pose
        let addedAt: Date
        var file: String { "\(id.uuidString).jpg" }
    }

    /// Newest date first; within a date, front, side, back, newest first.
    @Published private(set) var photos: [Photo] = []
    let folder: URL
    private let thumbnails = NSCache<NSString, UIImage>()

    /// The longest side a saved photo keeps, in pixels.
    nonisolated static let maximumPixels: CGFloat = 2048

    init(accountID: String, root: URL? = nil) {
        folder = (root ?? Self.root).appending(path: Self.folderName(accountID), directoryHint: .isDirectory)
        load()
    }

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "ProgressPhotos", directoryHint: .isDirectory)
    }

    static func folderName(_ accountID: String) -> String {
        String(accountID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    /// Removes a deleted account's photos.
    static func removeAll(accountID: String, root: URL? = nil) throws {
        let folder = (root ?? Self.root).appending(path: folderName(accountID), directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    private var index: URL { folder.appending(path: "index.json") }

    func load() {
        let saved = (try? Data(contentsOf: index)).flatMap { try? ExerlyJSON.decoder.decode([Photo].self, from: $0) } ?? []
        photos = Self.sorted(saved)
    }

    static func sorted(_ photos: [Photo]) -> [Photo] {
        let order = Dictionary(uniqueKeysWithValues: Pose.allCases.enumerated().map { ($1, $0) })
        return photos.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            if a.pose != b.pose { return order[a.pose, default: 0] < order[b.pose, default: 0] }
            return a.addedAt > b.addedAt
        }
    }

    /// Dates with photos, newest first.
    var dates: [LocalDate] {
        photos.map(\.date).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }

    func photos(on date: LocalDate) -> [Photo] { photos.filter { $0.date == date } }

    /// The newest photo of a pose on a date.
    func photo(on date: LocalDate, pose: Pose) -> Photo? { photos.first { $0.date == date && $0.pose == pose } }

    /// Saves an image as a JPEG no longer than `maximumPixels` on its longest side.
    @discardableResult
    func add(_ data: Data, date: LocalDate, pose: Pose, addedAt: Date = Date()) throws -> Photo {
        guard let jpeg = Self.jpeg(data) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // To the millisecond, as the index keeps it.
        let photo = Photo(id: UUID(), date: date, pose: pose, addedAt: addedAt.roundedToMilliseconds)
        try jpeg.write(to: folder.appending(path: photo.file), options: [.atomic, .completeFileProtection])
        do {
            try save(photos + [photo])
        } catch {
            try? FileManager.default.removeItem(at: folder.appending(path: photo.file))
            throw error
        }
        return photo
    }

    func delete(_ photo: Photo) throws {
        try save(photos.filter { $0.id != photo.id })
        try? FileManager.default.removeItem(at: url(photo))
        thumbnails.removeObject(forKey: photo.file as NSString)
    }

    func setPose(_ pose: Pose, for photo: Photo) throws {
        try save(photos.map { $0.id == photo.id ? Photo(id: $0.id, date: $0.date, pose: pose, addedAt: $0.addedAt) : $0 })
    }

    func url(_ photo: Photo) -> URL { folder.appending(path: photo.file) }

    func image(_ photo: Photo) -> UIImage? { UIImage(contentsOfFile: url(photo).path) }

    /// A small copy for grids, decoded once.
    func thumbnail(_ photo: Photo) -> UIImage? {
        if let cached = thumbnails.object(forKey: photo.file as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(url(photo) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        thumbnails.setObject(thumbnail, forKey: photo.file as NSString)
        return thumbnail
    }

    private func save(_ next: [Photo]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ExerlyJSON.canonical(next).write(to: index, options: [.atomic, .completeFileProtection])
        photos = Self.sorted(next)
    }

    /// The image upright, scaled down to `maximumPixels`, as a JPEG.
    nonisolated static func jpeg(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, maximumPixels / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
