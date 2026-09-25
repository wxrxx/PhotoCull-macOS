// PhotoCull – ViewModel/PhotoLibraryViewModel.swift
// Main view model driving the photo library state.

import Foundation
import Combine
import AppKit

// MARK: - Supporting Types

struct FilterState: Equatable {
    var showOnlyFlag: FlagStatus? = nil
    var minRating: StarRating = .unrated
    var showOnlyLabel: ColorLabel? = nil
}

enum SortOrder: String, CaseIterable {
    case filename  = "Filename"
    case dateTaken = "Date Taken"
    case rating    = "Rating"
    case flag      = "Flag"
}

// MARK: - PhotoLibraryViewModel

@MainActor
final class PhotoLibraryViewModel: ObservableObject {

    // MARK: Published State

    @Published var allPhotos: [PhotoItem] = []
    @Published var filteredPhotos: [PhotoItem] = []
    @Published var currentFolderURL: URL? = nil
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double = 0.0
    @Published var errorMessage: String? = nil

    @Published var filterState: FilterState = FilterState() {
        didSet { if filterState != oldValue { applyFilterAndSort() } }
    }
    @Published var sortOrder: SortOrder = .filename {
        didSet { applyFilterAndSort() }
    }
    @Published var selectedIDs: Set<Int64> = []

    /// Convenience: total count of all photos (before filtering).
    var allPhotosCount: Int { allPhotos.count }

    // MARK: Owned Services

    let imageService: ImageLoadingService
    let database: DatabaseService
    let exportService: ExportService

    // MARK: Private

    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic",
        "cr2", "nef", "arw", "dng", "raf", "rw2"
    ]
    private let batchSize = 50
    private var scanTask: Task<Void, Never>?

    // MARK: Init

    init(imageService: ImageLoadingService = ImageLoadingService(),
         database: DatabaseService = DatabaseService(),
         exportService: ExportService = ExportService()) {
        self.imageService = imageService
        self.database = database
        self.exportService = exportService
    }

    // MARK: - Folder Scanning

    func openFolder(_ url: URL) async {
        scanTask?.cancel()

        allPhotos = []
        filteredPhotos = []
        selectedIDs = []
        currentFolderURL = url
        isLoading = true
        loadingProgress = 0.0
        errorMessage = nil

        // Remember this folder
        Task { try? await database.upsertFolder(path: url.path) }

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await self.collectImageURLs(in: url)
                guard !urls.isEmpty else {
                    await MainActor.run {
                        self.isLoading = false
                        self.loadingProgress = 1.0
                    }
                    return
                }

                let total = urls.count
                var processed = 0

                for batchStart in stride(from: 0, to: total, by: self.batchSize) {
                    guard !Task.isCancelled else { break }

                    let batchEnd = min(batchStart + self.batchSize, total)
                    let batchURLs = Array(urls[batchStart..<batchEnd])

                    let rawItems = await self.buildPhotoItems(from: batchURLs)
                    guard !Task.isCancelled else { break }

                    let enrichedItems = await self.upsertAndEnrich(rawItems)
                    guard !Task.isCancelled else { break }

                    await MainActor.run {
                        self.allPhotos.append(contentsOf: enrichedItems)
                        processed += enrichedItems.count
                        self.loadingProgress = Double(processed) / Double(total)
                        self.applyFilterAndSort()
                    }
                }

                await MainActor.run {
                    self.isLoading = false
                    self.loadingProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Failed to open folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private func collectImageURLs(in directoryURL: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) { [supportedExtensions] in
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            return contents
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }

    private func buildPhotoItems(from urls: [URL]) async -> [PhotoItem] {
        await withTaskGroup(of: PhotoItem?.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    var item = try? PhotoItem.makeFromFile(url: url)
                    if item != nil {
                        item?.dateTaken = self.imageService.extractEXIFDate(from: url)
                    }
                    return item
                }
            }
            var results: [PhotoItem] = []
            results.reserveCapacity(urls.count)
            for await item in group {
                if let item { results.append(item) }
            }
            return results.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
    }

    private func upsertAndEnrich(_ items: [PhotoItem]) async -> [PhotoItem] {
        do {
            return try await database.upsertPhotos(items)
        } catch {
            return items
        }
    }

    // MARK: - Filter & Sort

    func applyFilterAndSort() {
        var result = allPhotos

        if let requiredFlag = filterState.showOnlyFlag {
            result = result.filter { $0.flag == requiredFlag }
        }
        if filterState.minRating != .unrated {
            result = result.filter { $0.rating >= filterState.minRating }
        }
        if let requiredLabel = filterState.showOnlyLabel {
            result = result.filter { $0.label == requiredLabel }
        }

        switch sortOrder {
        case .filename:
            result.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .dateTaken:
            result.sort { lhs, rhs in
                switch (lhs.dateTaken, rhs.dateTaken) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):   return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
                }
            }
        case .rating:
            result.sort { $0.rating.rawValue > $1.rating.rawValue }
        case .flag:
            result.sort { lhs, rhs in
                func order(_ f: FlagStatus) -> Int {
                    switch f { case .picked: return 0; case .rejected: return 1; case .unflagged: return 2 }
                }
                let lo = order(lhs.flag); let ro = order(rhs.flag)
                if lo != ro { return lo < ro }
                return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
            }
        }

        filteredPhotos = result
    }

    // MARK: - Optimistic Metadata Updates

    func setRating(_ rating: StarRating, for item: PhotoItem) {
        updateInPlace(item: item) { $0.rating = rating }
        applyFilterAndSort()
        if let id = item.id {
            Task { try? await database.updateRating(id: id, rating: rating) }
        }
    }

    func setFlag(_ flag: FlagStatus, for item: PhotoItem) {
        updateInPlace(item: item) { $0.flag = flag }
        applyFilterAndSort()
        if let id = item.id {
            Task { try? await database.updateFlag(id: id, flag: flag) }
        }
    }

    func setLabel(_ label: ColorLabel, for item: PhotoItem) {
        updateInPlace(item: item) { $0.label = label }
        applyFilterAndSort()
        if let id = item.id {
            Task { try? await database.updateLabel(id: id, label: label) }
        }
    }

    func setCrop(_ crop: CropRect?, for item: PhotoItem) {
        updateInPlace(item: item) { $0.cropRect = crop }
        if let id = item.id {
            Task { try? await database.updateCrop(id: id, cropRect: crop) }
        }
    }

    private func updateInPlace(item: PhotoItem, mutation: (inout PhotoItem) -> Void) {
        if let id = item.id, let idx = allPhotos.firstIndex(where: { $0.id == id }) {
            mutation(&allPhotos[idx])
        } else if let idx = allPhotos.firstIndex(where: { $0.filename == item.filename }) {
            mutation(&allPhotos[idx])
        }
    }

    // MARK: - Convenience Queries

    func pickedItems() -> [PhotoItem] {
        allPhotos.filter { $0.flag == .picked }
    }

    func selectedItems() -> [PhotoItem] {
        guard !selectedIDs.isEmpty else { return [] }
        return allPhotos.filter { guard let id = $0.id else { return false }; return selectedIDs.contains(id) }
    }

    func indexInFiltered(for item: PhotoItem) -> Int? {
        if let id = item.id { return filteredPhotos.firstIndex { $0.id == id } }
        return filteredPhotos.firstIndex { $0.filename == item.filename }
    }
}
