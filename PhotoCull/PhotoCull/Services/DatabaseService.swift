// PhotoCull – Services/DatabaseService.swift
// Actor-isolated SQLite database via GRDB.

import Foundation
import GRDB

// MARK: - DatabaseService

actor DatabaseService {

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    init() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dbDir = appSupport.appendingPathComponent("PhotoCull", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbURL = dbDir.appendingPathComponent("photocull.db")

            var config = Configuration()
            config.label = "PhotoCull"
            dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
            try DatabaseService.runMigrations(on: dbQueue)
        } catch {
            fatalError("DatabaseService: failed to initialise – \(error)")
        }
    }

    // MARK: - Migrations

    private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "photos", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_path", .text).notNull().unique()
                t.column("filename",          .text)
                t.column("file_size",         .integer)
                t.column("modification_date", .double)
                t.column("date_taken",        .double)
                t.column("rating",            .integer).defaults(to: 0)
                t.column("flag",              .text).defaults(to: "unflagged")
                t.column("label",             .text).defaults(to: "none")
                t.column("crop_x",            .double)
                t.column("crop_y",            .double)
                t.column("crop_width",        .double)
                t.column("crop_height",       .double)
                t.column("crop_aspect",       .text)
            }

            try db.create(table: "folders", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path",        .text).unique()
                t.column("last_opened", .double)
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Photo CRUD

    /// Insert or update a single photo. Returns the item with id populated.
    func upsertPhoto(_ item: PhotoItem) async throws -> PhotoItem {
        try dbQueue.write { db in
            // Check if it already exists by source_path
            if let row = try Row.fetchOne(db,
                sql: "SELECT id, rating, flag, label, crop_x, crop_y, crop_width, crop_height, crop_aspect, date_taken FROM photos WHERE source_path = ?",
                arguments: [item.sourceURL.path]) {

                // Existing row: preserve user metadata, update file metadata
                let existingId: Int64 = row["id"]
                try db.execute(
                    sql: """
                        UPDATE photos SET filename = ?, file_size = ?, modification_date = ?,
                            date_taken = COALESCE(?, date_taken)
                        WHERE id = ?
                        """,
                    arguments: [item.filename, item.fileSize,
                                item.modificationDate.timeIntervalSince1970,
                                item.dateTaken?.timeIntervalSince1970,
                                existingId])

                // Re-fetch the full row to return enriched item
                guard let fetched = try Row.fetchOne(db, sql: "SELECT * FROM photos WHERE id = ?", arguments: [existingId]) else {
                    throw NSError(domain: "DatabaseService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to re-fetch updated row."])
                }
                return DatabaseService.photoItem(from: fetched)
            } else {
                // New row
                try db.execute(
                    sql: """
                        INSERT INTO photos (source_path, filename, file_size, modification_date, date_taken,
                            rating, flag, label) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [item.sourceURL.path, item.filename, item.fileSize,
                                item.modificationDate.timeIntervalSince1970,
                                item.dateTaken?.timeIntervalSince1970,
                                item.rating.rawValue, item.flag.rawValue, item.label.rawValue])
                let rowId = db.lastInsertedRowID
                var result = item
                result.id = rowId
                return result
            }
        }
    }

    /// Batch upsert. Returns items with existing DB metadata merged.
    func upsertPhotos(_ items: [PhotoItem]) async throws -> [PhotoItem] {
        try dbQueue.write { db in
            var results: [PhotoItem] = []
            for item in items {
                if let row = try Row.fetchOne(db,
                    sql: "SELECT * FROM photos WHERE source_path = ?",
                    arguments: [item.sourceURL.path]) {
                    // Already exists: return existing row (preserves ratings)
                    let rowId: Int64 = row["id"]
                    try db.execute(
                        sql: "UPDATE photos SET modification_date = ?, date_taken = COALESCE(?, date_taken) WHERE id = ?",
                        arguments: [item.modificationDate.timeIntervalSince1970,
                                    item.dateTaken?.timeIntervalSince1970,
                                    rowId])
                    guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM photos WHERE id = ?", arguments: [rowId]) else {
                        throw NSError(domain: "DatabaseService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to re-fetch updated row."])
                    }
                    results.append(DatabaseService.photoItem(from: updated))
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO photos (source_path, filename, file_size, modification_date,
                                date_taken, rating, flag, label) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [item.sourceURL.path, item.filename, item.fileSize,
                                    item.modificationDate.timeIntervalSince1970,
                                    item.dateTaken?.timeIntervalSince1970,
                                    item.rating.rawValue, item.flag.rawValue, item.label.rawValue])
                    var newItem = item
                    newItem.id = db.lastInsertedRowID
                    results.append(newItem)
                }
            }
            return results
        }
    }

    func updateRating(id: Int64, rating: StarRating) async throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE photos SET rating = ? WHERE id = ?",
                           arguments: [rating.rawValue, id])
        }
    }

    func updateFlag(id: Int64, flag: FlagStatus) async throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE photos SET flag = ? WHERE id = ?",
                           arguments: [flag.rawValue, id])
        }
    }

    func updateLabel(id: Int64, label: ColorLabel) async throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE photos SET label = ? WHERE id = ?",
                           arguments: [label.rawValue, id])
        }
    }

    func updateCrop(id: Int64, cropRect: CropRect?) async throws {
        try dbQueue.write { db in
            if let crop = cropRect {
                try db.execute(
                    sql: "UPDATE photos SET crop_x = ?, crop_y = ?, crop_width = ?, crop_height = ?, crop_aspect = ? WHERE id = ?",
                    arguments: [crop.x, crop.y, crop.width, crop.height, crop.aspect.rawValue, id])
            } else {
                try db.execute(
                    sql: "UPDATE photos SET crop_x = NULL, crop_y = NULL, crop_width = NULL, crop_height = NULL, crop_aspect = NULL WHERE id = ?",
                    arguments: [id])
            }
        }
    }

    func fetchPhotos(inFolderPath path: String) async throws -> [PhotoItem] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT * FROM photos WHERE source_path LIKE ? ORDER BY filename COLLATE NOCASE",
                arguments: ["\(prefix)%"])
            return rows.map { DatabaseService.photoItem(from: $0) }
        }
    }

    // MARK: - Folder Methods

    func upsertFolder(path: String) async throws {
        let now = Date().timeIntervalSince1970
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO folders (path, last_opened) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET last_opened = excluded.last_opened",
                arguments: [path, now])
        }
    }

    func fetchRecentFolderPaths(limit: Int = 10) async throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT path FROM folders ORDER BY last_opened DESC LIMIT ?",
                arguments: [limit])
            return rows.compactMap { $0["path"] as String? }
        }
    }

    // MARK: - Row → PhotoItem

    private static func photoItem(from row: Row) -> PhotoItem {
        let path: String = row["source_path"]
        let url = URL(fileURLWithPath: path)
        let modTime: Double = row["modification_date"] ?? 0
        let dateTakenTime: Double? = row["date_taken"]

        var cropRect: CropRect? = nil
        if let cx: Double = row["crop_x"],
           let cy: Double = row["crop_y"],
           let cw: Double = row["crop_width"],
           let ch: Double = row["crop_height"],
           let caStr: String = row["crop_aspect"],
           let ca = AspectPreset(rawValue: caStr) {
            cropRect = CropRect(x: cx, y: cy, width: cw, height: ch, aspect: ca)
        }

        return PhotoItem(
            id: row["id"],
            sourceURL: url,
            filename: row["filename"] ?? url.lastPathComponent,
            fileSize: row["file_size"] ?? 0,
            modificationDate: Date(timeIntervalSince1970: modTime),
            dateTaken: dateTakenTime.map { Date(timeIntervalSince1970: $0) },
            rating: StarRating(rawValue: row["rating"] ?? 0) ?? .unrated,
            flag: FlagStatus(rawValue: row["flag"] ?? "unflagged") ?? .unflagged,
            label: ColorLabel(rawValue: row["label"] ?? "none") ?? .none,
            cropRect: cropRect
        )
    }
}
