// ExportService.swift
// PhotoCull
//
// Handles all export operations: reveal in Finder, open with external app,
// copy picks (original or cropped JPEG), and destination folder picking.

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - CropExportMode

/// Controls whether exported files are copied verbatim or re-encoded as JPEG with crop applied.
enum CropExportMode {
    /// Copy the original source file byte-for-byte — fast, lossless.
    case originalFile
    /// Render a cropped JPEG at the specified quality (0.0 – 1.0).
    case croppedJPEG(quality: Float)
}

// MARK: - ExportError

enum ExportError: LocalizedError {
    case imageSourceCreationFailed(URL)
    case imageCreationFailed
    case destinationCreationFailed(URL)
    case finalizationFailed
    case bookmarkResolutionFailed

    var errorDescription: String? {
        switch self {
        case .imageSourceCreationFailed(let url):
            return "Could not open image source at \(url.lastPathComponent)."
        case .imageCreationFailed:
            return "Could not decode image data."
        case .destinationCreationFailed(let url):
            return "Could not create output file at \(url.lastPathComponent)."
        case .finalizationFailed:
            return "Failed to finalize JPEG export."
        case .bookmarkResolutionFailed:
            return "Could not resolve saved folder bookmark."
        }
    }
}

// MARK: - ExportService

/// Actor that centralises all export / reveal / open-with logic.
/// Runs on a detached thread-pool executor so heavy I/O never blocks the main actor.
actor ExportService {

    // MARK: UserDefaults keys

    private enum DefaultsKey {
        static let lastUsedAppURL       = "lastUsedAppURL"
        static let lastUsedExportFolder = "lastUsedExportFolder"
    }

    // MARK: - Reveal in Finder

    /// Selects each item's source file in a Finder window.
    func revealInFinder(_ items: [PhotoItem]) {
        let urls = items.map { $0.sourceURL }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Open With

    /// Opens every item's source file in the given application.
    func openWith(appURL: URL, items: [PhotoItem]) {
        let urls = items.map { $0.sourceURL }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)

        // Persist the choice for next time.
        persistAppURL(appURL)
    }

    /// Presents an NSOpenPanel so the user can pick an `.app` bundle,
    /// then opens the selected items with that application.
    ///
    /// Must be called from the main thread context; the panel is modal to `window`.
    @MainActor
    func showOpenWithPicker(for items: [PhotoItem], in window: NSWindow) {
        let panel = NSOpenPanel()
        panel.title                = "Open With…"
        panel.message              = "Choose an application to open the selected photos."
        panel.prompt               = "Open"
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL         = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes  = [.applicationBundle]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let appURL = panel.url, let self else { return }
            Task {
                await self.openWith(appURL: appURL, items: items)
            }
        }
    }

    /// Returns the last application URL chosen via ``showOpenWithPicker(for:in:)``.
    var lastUsedAppURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.lastUsedAppURL) else {
            return nil
        }
        return resolveBookmark(data)
    }

    // MARK: - Copy Picks

    /// Copies (or re-encodes) the supplied items into `destinationFolder`.
    ///
    /// - Parameters:
    ///   - items: The photos to export.
    ///   - destinationFolder: Target directory (must already exist or be creatable).
    ///   - cropMode: Whether to copy verbatim or render a cropped JPEG.
    ///   - progress: Called on the calling actor with a fraction in `0.0 … 1.0`.
    func copyFiles(
        _ items: [PhotoItem],
        to destinationFolder: URL,
        cropMode: CropExportMode,
        progress: @escaping (Double) -> Void
    ) async throws {

        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationFolder.path) {
            try fm.createDirectory(at: destinationFolder,
                                   withIntermediateDirectories: true)
        }

        let total = Double(items.count)

        for (index, item) in items.enumerated() {
            switch cropMode {
            case .originalFile:
                let dest = uniqueDestinationURL(for: item, in: destinationFolder)
                try fm.copyItem(at: item.sourceURL, to: dest)

            case .croppedJPEG(let quality):
                _ = try await renderCroppedJPEG(item: item,
                                                quality: quality,
                                                destinationFolder: destinationFolder)
            }

            let fraction = Double(index + 1) / total
            progress(fraction)
        }

        // Persist the destination for next time.
        persistFolderURL(destinationFolder)
    }

    /// Returns the last export-folder URL chosen by the user.
    var lastUsedExportFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.lastUsedExportFolder) else {
            return nil
        }
        return resolveBookmark(data)
    }

    // MARK: - Destination Folder Picker

    /// Presents an NSOpenPanel so the user can choose an export destination.
    /// Returns the chosen URL, or `nil` if the panel was cancelled.
    @MainActor
    func showDestinationPicker(in window: NSWindow) async -> URL? {
        let panel = NSOpenPanel()
        panel.title                   = "Choose Export Folder"
        panel.message                 = "Select the folder where your picks will be saved."
        panel.prompt                  = "Choose"
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.canCreateDirectories    = true
        panel.allowsMultipleSelection = false

        // Pre-select the last used folder if available.
        if let last = await lastUsedExportFolder {
            panel.directoryURL = last
        }

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }

        guard response == .OK, let url = panel.url else { return nil }
        await persistFolderURL(url)
        return url
    }

    // MARK: - Crop Rendering (private)

    /// Renders a JPEG from `item`, applying EXIF orientation correction and optional crop.
    ///
    /// - Parameters:
    ///   - item:              The photo to render.
    ///   - quality:           JPEG compression quality (0.0 – 1.0).
    ///   - destinationFolder: Directory in which to create the output file.
    /// - Returns: The URL of the newly created JPEG file.
    private func renderCroppedJPEG(
        item: PhotoItem,
        quality: Float,
        destinationFolder: URL
    ) async throws -> URL {

        // ── a. Open image source ──────────────────────────────────────────────
        guard let source = CGImageSourceCreateWithURL(item.sourceURL as CFURL, nil) else {
            throw ExportError.imageSourceCreationFailed(item.sourceURL)
        }

        // ── b. Read EXIF orientation ──────────────────────────────────────────
        let exifOrientation: CGImagePropertyOrientation = {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let raw = props?[kCGImagePropertyOrientation] as? UInt32,
               let ori = CGImagePropertyOrientation(rawValue: raw) {
                return ori
            }
            return .up
        }()

        // ── c. Decode full CGImage ────────────────────────────────────────────
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let rawImage = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw ExportError.imageCreationFailed
        }

        // ── d. Apply orientation via CGAffineTransform on a CGContext ─────────
        let orientedImage = try applyOrientation(to: rawImage, orientation: exifOrientation)

        // ── e. Apply crop if present ──────────────────────────────────────────
        let croppedImage: CGImage
        if let cropRect = item.cropRect {
            let pw = CGFloat(orientedImage.width)
            let ph = CGFloat(orientedImage.height)
            let pixelRect = CGRect(
                x:      CGFloat(cropRect.x)      * pw,
                y:      CGFloat(cropRect.y)      * ph,
                width:  CGFloat(cropRect.width)  * pw,
                height: CGFloat(cropRect.height) * ph
            )
            // CGImageCreateWithImageInRect uses flipped y-axis relative to Core Image;
            // because CGImage has origin at top-left we clamp to valid bounds.
            let bounded = pixelRect.intersection(CGRect(origin: .zero,
                                                        size: CGSize(width: pw, height: ph)))
            if let cut = orientedImage.cropping(to: bounded) {
                croppedImage = cut
            } else {
                croppedImage = orientedImage
            }
        } else {
            croppedImage = orientedImage
        }

        // ── f. Determine color space ──────────────────────────────────────────
        let colorSpace: CGColorSpace = croppedImage.colorSpace
            ?? CGColorSpaceCreateDeviceRGB()

        // ── g. Create destination file ────────────────────────────────────────
        let destURL = uniqueDestinationURL(for: item,
                                           in: destinationFolder,
                                           extension: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            destURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        ) else {
            throw ExportError.destinationCreationFailed(destURL)
        }

        // ── h & i. Add image with JPEG quality, color profile, reset orientation ──
        let outputProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: false,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            // Embed the ICC profile so color accuracy is preserved.
            kCGImagePropertyProfileName: colorSpace.name as Any,
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue, // reset to Normal
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifPixelXDimension: croppedImage.width,
                kCGImagePropertyExifPixelYDimension: croppedImage.height
            ] as [CFString: Any]
        ]

        CGImageDestinationAddImage(dest, croppedImage, outputProps as CFDictionary)

        // ── j. Finalize ───────────────────────────────────────────────────────
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.finalizationFailed
        }

        // ── k. Return URL ─────────────────────────────────────────────────────
        return destURL
    }

    // MARK: - Orientation Helpers

    /// Draws `image` into a new context with the orientation correction applied
    /// so the result is always in the "up" (standard) orientation.
    private func applyOrientation(
        to image: CGImage,
        orientation: CGImagePropertyOrientation
    ) throws -> CGImage {

        let srcWidth  = image.width
        let srcHeight = image.height

        // Determine output dimensions (width/height swap for 90° rotations).
        let swapDimensions: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            swapDimensions = true
        default:
            swapDimensions = false
        }

        let outWidth  = swapDimensions ? srcHeight : srcWidth
        let outHeight = swapDimensions ? srcWidth  : srcHeight

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outWidth, height: outHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            throw ExportError.imageCreationFailed
        }

        ctx.interpolationQuality = .high

        // Move origin to centre, apply transform, then translate back.
        ctx.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        ctx.concatenate(affineTransform(for: orientation,
                                        width: CGFloat(srcWidth),
                                        height: CGFloat(srcHeight)))
        ctx.translateBy(x: -CGFloat(srcWidth) / 2, y: -CGFloat(srcHeight) / 2)

        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: CGFloat(srcWidth),
                                   height: CGFloat(srcHeight)))

        guard let result = ctx.makeImage() else {
            throw ExportError.imageCreationFailed
        }
        return result
    }

    /// Returns the CGAffineTransform that maps `orientation` to `.up`.
    ///
    /// The transform is applied with the context origin translated to the centre of
    /// the *output* canvas (see ``applyOrientation(to:orientation:)``).
    private func affineTransform(
        for orientation: CGImagePropertyOrientation,
        width: CGFloat,
        height: CGFloat
    ) -> CGAffineTransform {
        switch orientation {
        case .up:
            return .identity
        case .upMirrored:
            return CGAffineTransform(scaleX: -1, y: 1)
        case .down:
            return CGAffineTransform(rotationAngle: .pi)
        case .downMirrored:
            return CGAffineTransform(scaleX: 1, y: -1)
        case .left:
            // 90° CCW
            return CGAffineTransform(rotationAngle: -.pi / 2)
        case .leftMirrored:
            return CGAffineTransform(scaleX: -1, y: 1)
                .rotated(by: -.pi / 2)
        case .right:
            // 90° CW
            return CGAffineTransform(rotationAngle: .pi / 2)
        case .rightMirrored:
            return CGAffineTransform(scaleX: -1, y: 1)
                .rotated(by: .pi / 2)
        }
    }

    // MARK: - Persistence Helpers

    private func persistAppURL(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.lastUsedAppURL)
        }
    }

    private func persistFolderURL(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.lastUsedExportFolder)
        }
    }

    /// Resolves a security-scoped bookmark back to a live URL.
    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        let url = try? URL(resolvingBookmarkData: data,
                           options: .withSecurityScope,
                           relativeTo: nil,
                           bookmarkDataIsStale: &stale)
        if stale {
            // Attempt to refresh the bookmark silently.
            if let fresh = url,
               let updated = try? fresh.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                UserDefaults.standard.set(updated,
                                          forKey: stale ? DefaultsKey.lastUsedExportFolder
                                                        : DefaultsKey.lastUsedAppURL)
            }
        }
        return url
    }

    // MARK: - File Naming Helpers

    /// Returns a destination URL that does not already exist, appending a counter if needed.
    private func uniqueDestinationURL(
        for item: PhotoItem,
        in folder: URL,
        extension ext: String? = nil
    ) -> URL {
        let fm        = FileManager.default
        let base      = (item.filename as NSString).deletingPathExtension
        let fileExt   = ext ?? (item.filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(item.filename)

        if let ext { candidate = folder.appendingPathComponent(base).appendingPathExtension(ext) }

        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let name  = "\(base)_\(counter)"
            candidate = folder.appendingPathComponent(name).appendingPathExtension(fileExt)
            counter  += 1
        }
        return candidate
    }
}
