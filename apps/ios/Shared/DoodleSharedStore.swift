import Foundation
import ImageIO
import UIKit
import WidgetKit

enum DoodleAppGroup {
    static let id = "group.app.doodle.ios"
    static let widgetKind = "DoodleHomeWidget"
    static let imageFileName = "latest-doodle.jpg"
    static let metaKey = "latestDoodleMeta"
    /// Keep widget memory tiny — Home Screen widgets are strict.
    static let maxImageDimension: CGFloat = 512

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var imageURL: URL? {
        containerURL?.appendingPathComponent("Library/Caches", isDirectory: true).appendingPathComponent(imageFileName)
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }
}

struct SharedDoodleMeta: Codable, Equatable {
    var id: String
    var senderName: String
    var createdAt: Date
    var hasPhoto: Bool

    var relativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(createdAt)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    var timeLabel: String {
        relativeTime == "now" ? "now" : "\(relativeTime) ago"
    }
}

enum DoodleSharedStore {
    /// Pass `reloadTimelines: false` when calling from the widget itself (it is already reloading).
    static func save(image: UIImage, meta: SharedDoodleMeta, reloadTimelines: Bool = true) {
        guard let container = DoodleAppGroup.containerURL else {
            print("DoodleSharedStore: App Group container unavailable. Check entitlements.")
            return
        }

        for legacy in ["latest-doodle.png", "latest-doodle.jpg"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(legacy))
        }

        let resized = resize(image, maxDimension: DoodleAppGroup.maxImageDimension)
        guard let imageURL = DoodleAppGroup.imageURL else { return }
        try? FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = resized.jpegData(compressionQuality: 0.82) {
            try? data.write(to: imageURL, options: .atomic)
        }

        if let encoded = try? JSONEncoder().encode(meta) {
            DoodleAppGroup.sharedDefaults?.set(encoded, forKey: DoodleAppGroup.metaKey)
            DoodleAppGroup.sharedDefaults?.synchronize()
        }

        if reloadTimelines { WidgetCenter.shared.reloadAllTimelines() }
    }

    static func loadMeta() -> SharedDoodleMeta? {
        guard
            let data = DoodleAppGroup.sharedDefaults?.data(forKey: DoodleAppGroup.metaKey),
            let meta = try? JSONDecoder().decode(SharedDoodleMeta.self, from: data)
        else { return nil }
        return meta
    }

    static func loadImage() -> UIImage? {
        guard
            let imageURL = DoodleAppGroup.imageURL,
            let imageData = try? Data(contentsOf: imageURL)
        else { return nil }
        return UIImage(data: imageData)
    }

    /// WidgetKit rejects archives whose images exceed a limit proportional to the widget's
    /// pixel area, so each family must get an image sized to its own display size.
    static func loadImage(maxPixelSize: CGFloat) -> UIImage? {
        guard
            let imageURL = DoodleAppGroup.imageURL,
            let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func load() -> (image: UIImage, meta: SharedDoodleMeta)? {
        guard let meta = loadMeta(), let image = loadImage() else { return nil }
        return (image, meta)
    }

    static func clear(reloadTimelines: Bool = true) {
        if let imageURL = DoodleAppGroup.imageURL {
            try? FileManager.default.removeItem(at: imageURL)
        }
        if let container = DoodleAppGroup.containerURL {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("latest-doodle.png"))
        }
        DoodleAppGroup.sharedDefaults?.removeObject(forKey: DoodleAppGroup.metaKey)
        if reloadTimelines { WidgetCenter.shared.reloadAllTimelines() }
    }

    private static func resize(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let scale = maxDimension / longest
        let newSize = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
