// PhotoCull – Models/PhotoItem.swift
// Central model representing a single photo file and all its cull metadata.

import Foundation

// MARK: - Supporting Enums

/// Star rating 0 (unrated) through 5.
enum StarRating: Int, Codable, Comparable {
    case unrated = 0
    case one = 1, two = 2, three = 3, four = 4, five = 5

    static func < (lhs: StarRating, rhs: StarRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Pick / Reject / Unflagged flag state.
enum FlagStatus: String, Codable {
    case unflagged = "unflagged"
    case picked    = "picked"
    case rejected  = "rejected"
}

/// Colour label for quick visual grouping.
enum ColorLabel: String, Codable {
    case none   = "none"
    case red    = "red"
    case yellow = "yellow"
    case green  = "green"
    case blue   = "blue"
    case purple = "purple"
}

/// Aspect ratio preset stored alongside a crop rect.
enum AspectPreset: String, Codable {
    case free     = "free"
    case square   = "1:1"
    case portrait = "4:5"
    case wide     = "16:9"
    case original = "original"

    /// Returns the required width/height ratio, or nil for .free / .original.
    var ratio: CGFloat? {
        switch self {
        case .free:     return nil
        case .square:   return 1
        case .portrait: return 4.0 / 5.0
        case .wide:     return 16.0 / 9.0
        case .original: return nil
        }
    }
}

// MARK: - CropRect

/// Normalised crop rectangle (0.0 – 1.0 relative to full-size image dimensions).
struct CropRect: Equatable, Codable {
    var x: Double       // left edge
    var y: Double       // top edge
    var width: Double
    var height: Double
    var aspect: AspectPreset

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1, aspect: .original)

    var isEmpty: Bool { x == 0 && y == 0 && width == 1 && height == 1 }

    /// Convert to CGRect (normalised 0–1 range).
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Create from a CGRect (normalised 0–1 range) with an aspect preset.
    init(cgRect: CGRect, aspect: AspectPreset) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
        self.aspect = aspect
    }

    init(x: Double, y: Double, width: Double, height: Double, aspect: AspectPreset) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.aspect = aspect
    }
}

// MARK: - PhotoItem

/// The primary model object. Each instance corresponds to one image file on disk.
struct PhotoItem: Identifiable, Equatable {

    // MARK: Identity
    var id: Int64?                   // SQLite rowid (nil before first insert)
    let sourceURL: URL               // absolute path to the original file on disk

    // MARK: File metadata (loaded once, immutable)
    let filename: String
    let fileSize: Int64              // bytes
    let modificationDate: Date
    var dateTaken: Date?             // from EXIF DateTimeOriginal if available

    // MARK: Mutable cull metadata (updated by user actions)
    var rating: StarRating  = .unrated
    var flag: FlagStatus    = .unflagged
    var label: ColorLabel   = .none

    // MARK: Non-destructive crop (nil = no crop applied)
    var cropRect: CropRect? = nil

    // MARK: Computed helpers
    var displayDate: Date { dateTaken ?? modificationDate }

    var hasCrop: Bool { cropRect != nil && cropRect?.isEmpty == false }

    /// The stable identifier used for caching and equality checks independent of rowid.
    var cacheKey: String { "\(sourceURL.path)|\(modificationDate.timeIntervalSince1970)" }
}

// MARK: - Convenience Factory

extension PhotoItem {
    /// Create a new (unsaved) PhotoItem from a file URL.
    /// Reads file attributes synchronously — call from a background context.
    static func makeFromFile(url: URL) throws -> PhotoItem {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
        let size    = (attrs[.size] as? Int64) ?? 0

        return PhotoItem(
            id:               nil,
            sourceURL:        url,
            filename:         url.lastPathComponent,
            fileSize:         size,
            modificationDate: modDate,
            dateTaken:        nil
        )
    }
}
