// PhotoCull – Services/ImageLoadingService.swift
// Performance-critical image loading, caching, and pre-fetching service.
//
// Architecture:
//   ThumbnailCache   – two-tier (memory + disk) thumbnail cache, class-based for NSCache
//   FullResCache     – actor-isolated NSCache for full-resolution images (512 MB cap)
//   ImageLoadingService – actor that owns both caches and drives all I/O
//   PreloadQueue     – actor that manages a sliding-window pre-fetch strategy

import Foundation
import AppKit
import ImageIO
import CryptoKit

// MARK: - Constants

private enum C {
    /// File extensions treated as RAW camera formats.
    static let rawExtensions: Set<String> = ["cr2", "nef", "arw", "dng", "raf", "rw2"]
    /// EXIF date string format used by virtually every camera vendor.
    static let exifDateFormat = "yyyy:MM:dd HH:mm:ss"
    /// Thumbnail JPEG quality written to the disk cache.
    static let thumbJPEGQuality: CGFloat = 0.75
    /// Disk cache sub-directory name.
    static let diskCacheFolder = "PhotoCull/thumbs"
}

// MARK: - ThumbnailCache

/// Two-tier thumbnail cache: NSCache (memory) + JPEG files on disk.
/// Thread-safe: NSCache is inherently thread-safe; disk I/O is serialised
/// per-item via actor-level await in ImageLoadingService.
final class ThumbnailCache {

    // MARK: Memory tier
    private let memCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.name = "com.photocull.thumbnailMemCache"
        c.countLimit = 500
        return c
    }()

    // MARK: Disk tier
    private let diskCacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(C.diskCacheFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Cache key helpers

    /// Returns a hex-encoded SHA-256 digest of the given string.
    private func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Composite memory-cache key encodes both path and target size so that
    /// different requested sizes are stored independently.
    private func memKey(for item: PhotoItem, size: CGFloat) -> NSString {
        "\(item.cacheKey)@\(Int(size))" as NSString
    }

    /// Disk filename is a SHA-256 of the composite key to avoid FS special chars.
    private func diskURL(for item: PhotoItem, size: CGFloat) -> URL {
        let key = "\(item.cacheKey)@\(Int(size))"
        let filename = sha256Hex(key) + ".jpg"
        return diskCacheURL.appendingPathComponent(filename)
    }

    // MARK: - Public API

    /// Returns a thumbnail for `item` at the requested pixel `size`.
    /// Checks memory → disk → generates via ImageIO.  Writes to disk on a miss.
    func thumbnail(for item: PhotoItem, size: CGFloat) async -> NSImage? {
        let mKey = memKey(for: item, size: size)

        // 1. Memory hit
        if let cached = memCache.object(forKey: mKey) {
            return cached
        }

        // 2. Disk hit
        let dURL = diskURL(for: item, size: size)
        if FileManager.default.fileExists(atPath: dURL.path),
           let image = NSImage(contentsOf: dURL) {
            memCache.setObject(image, forKey: mKey)
            return image
        }

        // 3. Generate via ImageIO
        guard let image = await generateThumbnail(for: item, size: size) else {
            return nil
        }

        // 4. Persist to disk (best-effort, non-fatal)
        saveToDisk(image: image, at: dURL)

        // 5. Store in memory cache
        memCache.setObject(image, forKey: mKey)
        return image
    }

    // MARK: - Generation

    /// Uses ImageIO to create a scaled thumbnail, respecting EXIF orientation.
    private func generateThumbnail(for item: PhotoItem, size: CGFloat) async -> NSImage? {
        return await Task.detached(priority: .utility) { [weak self] in
            guard self != nil else { return nil }

            let url = item.sourceURL
            let ext = url.pathExtension.lowercased()
            let isRAW = C.rawExtensions.contains(ext)

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }

            // For RAW files prefer an embedded JPEG preview (faster, accurate colours).
            // kCGImageSourceCreateThumbnailFromImageAlways=false + kCGImageSourceCreateThumbnailFromImageIfAbsent=true
            // means: use embedded thumb if available, generate only when absent.
            let createFromAlways  = !isRAW  // true for JPEGs/HEICs, false for RAW
            let createFromAbsent  = true     // always fall back to decoding if no embedded thumb

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways:  createFromAlways,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: createFromAbsent,
                kCGImageSourceThumbnailMaxPixelSize:           Int(size),
                kCGImageSourceCreateThumbnailWithTransform:    true,  // apply EXIF orientation
                kCGImageSourceShouldCacheImmediately:          false
            ]

            guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            let nsImage = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
            return nsImage
        }.value
    }

    // MARK: - Disk write

    /// Writes `image` to `url` as a JPEG file at the configured quality level.
    private func saveToDisk(image: NSImage, at url: URL) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: C.thumbJPEGQuality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Cache management

    /// Evict all memory-cached thumbnails (disk cache is persistent).
    func evictMemory() {
        memCache.removeAllObjects()
    }
}

// MARK: - FullResCache

/// Actor-isolated NSCache for full-resolution images, capped at 512 MB.
/// Cost is computed as raw pixel byte count (width × height × 4 bytes/pixel).
actor FullResCache {

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.name = "com.photocull.fullResCache"
        c.countLimit = 12
        c.totalCostLimit = 536_870_912  // 512 MB
        return c
    }()

    // MARK: - Public API

    /// Returns a full-resolution image for `item`, or `nil` on a cache miss.
    func image(for item: PhotoItem) -> NSImage? {
        cache.object(forKey: item.cacheKey as NSString)
    }

    /// Stores `image` in the cache, using pixel byte count as cost.
    func store(_ image: NSImage, for item: PhotoItem) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: item.cacheKey as NSString, cost: cost)
    }

    /// Evicts all objects from the full-resolution cache immediately.
    func evictAll() {
        cache.removeAllObjects()
    }
}

// MARK: - ImageLoadingService

/// Actor that centralises all image I/O for the application.
/// Owns a `ThumbnailCache` and a `FullResCache`, routes requests appropriately,
/// and exposes helpers for EXIF metadata extraction.
actor ImageLoadingService {

    // MARK: Owned caches
    let thumbnailCache = ThumbnailCache()
    let fullResCache   = FullResCache()

    // MARK: - Thumbnail loading

    /// Returns a thumbnail for `item` at the requested pixel `size`.
    /// Delegates entirely to `ThumbnailCache`'s two-tier strategy.
    func loadThumbnail(for item: PhotoItem, size: CGFloat) async -> NSImage? {
        await thumbnailCache.thumbnail(for: item, size: size)
    }

    // MARK: - Full-resolution loading

    /// Loads the full-resolution image for `item`, applying the correct
    /// EXIF orientation transform so the image is always presented upright.
    func loadFullRes(for item: PhotoItem) async -> NSImage? {
        // 1. Full-res cache hit
        if let cached = await fullResCache.image(for: item) {
            return cached
        }

        // 2. Decode on a background thread
        let image = await Task.detached(priority: .userInitiated) { [item] in
            ImageLoadingService.decodeFullRes(from: item.sourceURL)
        }.value

        guard let image else { return nil }

        // 3. Store and return
        await fullResCache.store(image, for: item)
        return image
    }

    /// Synchronous, static helper — called inside a detached Task.
    private static func decodeFullRes(from url: URL) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache:          false,  // let the OS decide
            kCGImageSourceShouldAllowFloat:     true
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // Read the EXIF orientation value so we can rotate if needed.
        let orientation = exifOrientation(from: source)
        let nsImage: NSImage

        if let rotated = applying(orientation: orientation, to: cgImage) {
            nsImage = rotated
        } else {
            nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return nsImage
    }

    // MARK: - EXIF orientation helpers

    /// Reads `kCGImagePropertyOrientation` from the ImageIO source.
    private static func exifOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawValue = props[kCGImagePropertyOrientation] as? UInt32,
            let o = CGImagePropertyOrientation(rawValue: rawValue)
        else {
            return .up
        }
        return o
    }

    /// Returns a new NSImage whose pixel data is rotated/flipped to match `orientation`.
    /// Returns `nil` when the orientation is `.up` (no transform needed).
    private static func applying(orientation: CGImagePropertyOrientation, to cgImage: CGImage) -> NSImage? {
        guard orientation != .up else { return nil }

        let w = cgImage.width
        let h = cgImage.height

        // Determine the output size after potential 90-degree rotations.
        let swapAxes: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            swapAxes = true
        default:
            swapAxes = false
        }

        let outW = swapAxes ? h : w
        let outH = swapAxes ? w : h

        let bitsPerComponent = cgImage.bitsPerComponent
        let colorSpace       = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo       = cgImage.bitmapInfo

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.setAllowsAntialiasing(false)

        // Build the affine transform that corrects the orientation.
        var transform = CGAffineTransform.identity

        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: CGFloat(outW), y: CGFloat(outH))
            transform = transform.rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: CGFloat(outW), y: 0)
            transform = transform.rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: CGFloat(outH))
            transform = transform.rotated(by: -.pi / 2)
        default:
            break
        }

        switch orientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: CGFloat(outW), y: 0)
            transform = transform.scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: CGFloat(outH), y: 0)
            transform = transform.scaledBy(x: -1, y: 1)
        default:
            break
        }

        ctx.concatenate(transform)

        let drawRect = swapAxes
            ? CGRect(x: 0, y: 0, width: CGFloat(h), height: CGFloat(w))
            : CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))

        ctx.draw(cgImage, in: drawRect)

        guard let rotatedCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: rotatedCG, size: NSSize(width: outW, height: outH))
    }

    // MARK: - Thumbnail pre-fetching

    /// Batch-loads thumbnails for all items using a `TaskGroup`, so the OS can
    /// parallelise I/O across available cores without blowing out memory.
    func prefetchThumbnails(items: [PhotoItem], size: CGFloat) async {
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { [weak self] in
                    guard let self else { return }
                    _ = await self.loadThumbnail(for: item, size: size)
                }
            }
        }
    }

    // MARK: - EXIF date extraction

    /// Reads `kCGImagePropertyExifDateTimeOriginal` from the image file and
    /// parses it with the standard camera date format `yyyy:MM:dd HH:mm:ss`.
    ///
    /// - Returns: The parsed `Date`, or `nil` if the tag is absent / unparseable.
    nonisolated func extractEXIFDate(from url: URL) -> Date? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary),
            let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif   = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let rawDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        let fmt = DateFormatter()
        fmt.locale     = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = C.exifDateFormat
        return fmt.date(from: rawDate)
    }
}

// MARK: - PreloadQueue

/// Actor that manages a sliding-window pre-fetch strategy.
/// Keeps thumbnails for 5 items ahead and 2 items behind the current index
/// loaded in the background, cancelling stale tasks automatically.
actor PreloadQueue {

    // MARK: Configuration
    private let lookAhead:  Int = 5
    private let lookBehind: Int = 2

    // MARK: State
    /// Live Tasks keyed by their item index in the master array.
    private var tasks: [Int: Task<Void, Never>] = [:]

    // MARK: - Public API

    /// Call whenever the user navigates to `currentIndex`.
    /// - Cancels tasks whose indices fall outside the new window.
    /// - Launches thumbnail pre-fetches for newly entered window positions.
    func updateWindow(currentIndex: Int, items: [PhotoItem], service: ImageLoadingService) async {
        let lo  = max(0, currentIndex - lookBehind)
        let hi  = min(items.count - 1, currentIndex + lookAhead)
        let windowIndices = Set(lo...hi)

        // Cancel tasks that have fallen outside the window.
        let staleIndices = Set(tasks.keys).subtracting(windowIndices)
        for idx in staleIndices {
            tasks[idx]?.cancel()
            tasks.removeValue(forKey: idx)
        }

        // Launch tasks for indices in the window that aren't already loading.
        for idx in windowIndices where tasks[idx] == nil {
            let item = items[idx]
            tasks[idx] = Task(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                _ = await service.loadThumbnail(for: item, size: 256)
                // Remove ourselves from the map once complete.
                await self?.taskCompleted(for: idx)
            }
        }
    }

    /// Removes a completed task from the tracking dictionary.
    private func taskCompleted(for index: Int) {
        tasks.removeValue(forKey: index)
    }

    /// Cancel and clear every running pre-fetch task.
    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
