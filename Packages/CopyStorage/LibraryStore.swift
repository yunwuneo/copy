import Foundation
import CopyCore
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum SQLValue { case text(String), int(Int64), null }

/// One connection per process; the recursive lock serializes transactions and nested reads.
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fm = FileManager.default
    public var assetsURL: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
        try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
        guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); db = nil; throw CopyError.database("无法打开") }
        var ready = false
        defer { if !ready { sqlite3_close(db); db = nil } }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA secure_delete=ON")
        let version = try scalar("PRAGMA user_version")
        guard version <= 2 else { throw CopyError.invalid("数据来自更高版本，已停止打开以保护资料") }
        let checkpoint = version > 0 && version < 2 ? try migrationCheckpoint(version:version) : nil
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, captured REAL NOT NULL, history INTEGER NOT NULL, collection TEXT, kind TEXT NOT NULL, source TEXT, pending REAL, body TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS items_recent ON items(captured DESC, id)")
            try execute("CREATE INDEX IF NOT EXISTS items_fingerprint ON items(fingerprint)")
            try execute("CREATE INDEX IF NOT EXISTS items_collection ON items(collection)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, content, tokenize='trigram')")
            try execute("CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, body TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT UNIQUE NOT NULL, item TEXT NOT NULL, action TEXT NOT NULL, body TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS tombstones(id TEXT PRIMARY KEY, deleted REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS captures(id INTEGER PRIMARY KEY AUTOINCREMENT, item TEXT NOT NULL, time REAL NOT NULL, source TEXT)")
            try execute("CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, request TEXT NOT NULL, state TEXT NOT NULL, result TEXT)")
            if version < 2 { try rebuildIndex() }
            if checkpoint != nil, try rows("PRAGMA quick_check").first?.first != "ok" { throw CopyError.database("升级校验失败，旧库和迁移恢复点均保留") }
            try execute("PRAGMA user_version=2")
        }
        if try metadata(UUID.self, key: "libraryID") == nil { try setMetadata(UUID(), key: "libraryID") }
        if let checkpoint {
            try fm.removeItem(at:checkpoint)
        }
        ready = true
    }
    deinit { sqlite3_close(db) }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func statement(_ sql: String, _ args: [SQLValue] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }
        for (i, value) in args.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case .text(let v): sqlite3_bind_text(s, n, v, -1, transient)
            case .int(let v): sqlite3_bind_int64(s, n, v)
            case .null: sqlite3_bind_null(s, n)
            }
        }
        return s
    }
    private func error() -> CopyError { .database(String(cString: sqlite3_errmsg(db))) }
    private func migrationCheckpoint(version: Int64) throws -> URL {
        let file = root.appendingPathComponent("migration-recovery-v\(version).sqlite")
        guard !fm.fileExists(atPath:file.path) else { throw CopyError.unavailable("发现上次迁移恢复点，已停止迁移。原资料库和恢复点均保留，请先检查后再重试。") }
        let required = try scalar("PRAGMA page_count") * scalar("PRAGMA page_size") + 1024*1024
        guard Int64(try root.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0) > required else { throw CopyError.unavailable("空间不足以创建迁移恢复点，原资料库未升级") }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(file.path,&destination,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_EXCLUSIVE,nil) == SQLITE_OK, let destination else { if let destination { sqlite3_close(destination) }; throw CopyError.database("无法创建迁移恢复点") }
        var complete = false
        defer { sqlite3_close(destination); if !complete { try? fm.removeItem(at:file) } }
        guard let backup = sqlite3_backup_init(destination,"main",db,"main") else { throw CopyError.database("无法读取旧数据库快照") }
        let result = sqlite3_backup_step(backup,-1), finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw CopyError.database("迁移恢复点未完成，未进行升级") }
        complete = true
        return file
    }
    private func execute(_ sql: String, _ args: [SQLValue] = []) throws {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        let result = sqlite3_step(s)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
    }
    private func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [[String]] {
        let s = try statement(sql, args); defer { sqlite3_finalize(s) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw error() }
            result.append((0..<sqlite3_column_count(s)).map { i in sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" })
        }
        return result
    }
    private func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> Int64 { Int64(try rows(sql, args).first?.first ?? "0") ?? 0 }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        let nested = sqlite3_get_autocommit(db) == 0
        let point = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute(nested ? "SAVEPOINT \(point)" : "BEGIN IMMEDIATE")
        do { let result = try body(); try execute(nested ? "RELEASE \(point)" : "COMMIT"); return result }
        catch { try? execute(nested ? "ROLLBACK TO \(point)" : "ROLLBACK"); if nested { try? execute("RELEASE \(point)") }; throw error }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ body: String) throws -> T { try decoder.decode(type, from: Data(body.utf8)) }
    public func metadata<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        try synchronized { guard let row = try rows("SELECT body FROM metadata WHERE key=?", [.text(key)]).first else { return nil }; return try decode(type, row[0]) }
    }
    public func setMetadata<T: Encodable>(_ value: T, key: String) throws {
        try synchronized { try execute("INSERT INTO metadata(key,body) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET body=excluded.body", [.text(key), .text(try json(value))]) }
    }
    public func item(_ id: UUID, includePending: Bool = false) throws -> ClipItem? {
        try synchronized {
            guard let row = try rows("SELECT body FROM items WHERE id=?" + (includePending ? "" : " AND pending IS NULL"), [.text(id.uuidString)]).first else { return nil }
            return try decode(ClipItem.self, row[0])
        }
    }
    private func save(_ item: ClipItem, action: String = "upsert") throws {
        let body = try json(item)
        try execute("INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint,captured=excluded.captured,history=excluded.history,collection=excluded.collection,kind=excluded.kind,source=excluded.source,pending=excluded.pending,body=excluded.body", [
            .text(item.id.uuidString), .text(item.fingerprint), .text(String(item.captured.timeIntervalSince1970)), .int(item.inHistory ? 1 : 0), item.collectionID.map { .text($0.uuidString) } ?? .null, .text(item.kind.rawValue), item.source.map(SQLValue.text) ?? .null, item.pendingDeletion.map { .text(String($0.timeIntervalSince1970)) } ?? .null, .text(body)
        ])
        try execute("DELETE FROM search WHERE rowid=(SELECT rowid FROM items WHERE id=?)", [.text(item.id.uuidString)])
        if item.pendingDeletion == nil { try execute("INSERT INTO search(rowid,id,content) SELECT rowid,?,? FROM items WHERE id=?", [.text(item.id.uuidString), .text([item.title,item.text,item.ocr].joined(separator: "\n")),.text(item.id.uuidString)]) }
        try enqueue(item.id, action: action, body: body)
    }
    private func enqueue(_ id: UUID, action: String, body: String) throws {
        try execute("DELETE FROM outbox WHERE item=?", [.text(id.uuidString)])
        try execute("INSERT INTO outbox(operation,item,action,body) VALUES(?,?,?,?)", [.text(UUID().uuidString), .text(id.uuidString), .text(action), .text(body)])
    }
    public func capture(_ input: CaptureInput, budget: Int64 = 512 * 1024 * 1024, now: Date = Date(), deduplicate: Bool = true) throws -> ClipItem {
        try synchronized {
            try ContentRules.validate(input)
            let fingerprint = ContentRules.fingerprint(input.representations)
            return try transaction {
                if deduplicate, let row = try rows("SELECT body FROM items WHERE fingerprint=? AND pending IS NULL ORDER BY captured DESC LIMIT 1", [.text(fingerprint)]).first {
                    var existing = try decode(ClipItem.self, row[0]); existing.captured = now; existing.inHistory = true; existing.captureCount += 1; existing.revision += 1; existing.source = input.source
                    try save(existing); try recordCapture(existing, now: now); return existing
                }
                let needed = input.representations.values.reduce(Int64(0)) { sum, data in
                    sum + (fm.fileExists(atPath: assetsURL.appendingPathComponent(ContentRules.digest(data)).path) ? 0 : Int64(data.count))
                }
                guard try diskUsage() + needed + 64 * 1024 <= budget else { throw CopyError.budget }
                let resource = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                if input.kind == .image || input.kind == .files, (resource.volumeAvailableCapacity ?? 0) < 1024 * 1024 * 1024 { throw CopyError.unavailable("磁盘余量不足 1 GiB，附件采集已暂停") }
                var representations: [Representation] = []
                for type in input.representations.keys.sorted() {
                    let data = input.representations[type]!, digest = ContentRules.digest(data)
                    let destination = assetsURL.appendingPathComponent(digest)
                    if !fm.fileExists(atPath: destination.path) { try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen]) }
                    representations.append(Representation(type: type, digest: digest, bytes: data.count))
                }
                let item = ClipItem(kind: input.kind, text: input.text, source: input.source, representations: representations, fingerprint: fingerprint, now: now)
                try save(item); try recordCapture(item, now: now); return item
            }
        }
    }
    private func recordCapture(_ item: ClipItem, now: Date) throws {
        try execute("INSERT INTO captures(item,time,source) VALUES(?,?,?)", [.text(item.id.uuidString), .text(String(now.timeIntervalSince1970)), item.source.map(SQLValue.text) ?? .null])
    }
    public func data(for representation: Representation) throws -> Data {
        try synchronized {
            guard representation.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CopyError.invalid("附件标识") }
            let url = assetsURL.appendingPathComponent(representation.digest)
            guard let data = try? Data(contentsOf: url), data.count == representation.bytes, ContentRules.digest(data) == representation.digest else { throw CopyError.missingAsset(representation.digest) }
            return data
        }
    }
    public func search(_ query: SearchQuery) throws -> [ClipItem] {
        try synchronized {
            var predicates = ["pending IS NULL"], args: [SQLValue] = []
            if query.historyOnly { predicates.append("history=1") }
            if let collection = query.collectionID { predicates.append("collection=?"); args.append(.text(collection.uuidString)) }
            if !query.kinds.isEmpty { predicates.append("kind IN (\(Array(repeating: "?", count: query.kinds.count).joined(separator: ",")))"); args += query.kinds.sorted(by: { $0.rawValue < $1.rawValue }).map { .text($0.rawValue) } }
            if !query.sources.isEmpty { predicates.append("source IN (\(Array(repeating: "?", count: query.sources.count).joined(separator: ",")))"); args += query.sources.sorted().map(SQLValue.text) }
            if let date = query.from { predicates.append("captured>=?"); args.append(.text(String(date.timeIntervalSince1970))) }
            if let date = query.before { predicates.append("captured<?"); args.append(.text(String(date.timeIntervalSince1970))) }
            if let cursor = query.cursor {
                predicates.append("(captured<? OR (captured=? AND id>?))")
                args += [.text(String(cursor.captured.timeIntervalSince1970)),.text(String(cursor.captured.timeIntervalSince1970)),.text(cursor.id.uuidString)]
            }
            if !query.text.isEmpty {
                if query.text.unicodeScalars.count >= 3 {
                    predicates.append("rowid IN (SELECT rowid FROM search WHERE search MATCH ?)")
                    args.append(.text("\"" + query.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
                } else {
                    predicates.append("rowid IN (SELECT rowid FROM search WHERE instr(lower(content),lower(?))>0)")
                    args.append(.text(query.text))
                }
            }
            args += [.int(Int64(min(1000, max(1, query.limit)))), .int(Int64(max(0, query.offset)))]
            return try rows("SELECT body FROM items WHERE " + predicates.joined(separator: " AND ") + (query.collectionID == nil || !query.useCollectionOrder ? " ORDER BY captured DESC,id ASC" : " ORDER BY COALESCE(json_extract(body,'$.collectionOrder'),2147483647),captured DESC,id ASC") + " LIMIT ? OFFSET ?", args).map { try decode(ClipItem.self, $0[0]) }
        }
    }
    public func update(_ id: UUID, expectedRevision: Int, mutate: (inout ClipItem) throws -> Void) throws -> ClipItem {
        try synchronized { try transaction {
            guard var item = try item(id) else { throw CopyError.notFound }
            guard item.revision == expectedRevision else { throw CopyError.conflict }
            try mutate(&item); item.revision += 1
            if let collection = item.collectionID { guard try scalar("SELECT count(*) FROM collections WHERE id=?", [.text(collection.uuidString)]) == 1 else { throw CopyError.notFound } }
            try save(item); return item
        } }
    }
    public func editText(_ id: UUID, expectedRevision: Int, title: String, text: String, budget: Int64 = 512 * 1024 * 1024) throws -> ClipItem {
        try synchronized { try transaction {
            guard let existing = try item(id), existing.revision == expectedRevision else { throw CopyError.conflict }
            guard try diskUsage() + Int64(text.utf8.count) + 65536 <= budget else { throw CopyError.budget }
            guard text.utf8.count <= 5 * 1024 * 1024 else { throw CopyError.invalid("文本超过 5 MiB") }
            let bytes = Data(text.utf8), hash = ContentRules.digest(bytes)
            // A replacement explicitly becomes plain text; original rich representations must not disagree.
            let path = assetsURL.appendingPathComponent(hash)
            if !fm.fileExists(atPath: path.path) { try bytes.write(to: path, options: .atomic) }
            return try update(id, expectedRevision: expectedRevision) { item in
                item.title = title; item.text = text; item.ocr = ""; item.kind = ContentRules.kind(types: ["public.utf8-plain-text"], text: text)
                item.representations = [.init(type: "public.utf8-plain-text", digest: hash, bytes: bytes.count)]
                item.fingerprint = ContentRules.fingerprint(["public.utf8-plain-text": bytes])
            }
        } }
    }
    public func collections() throws -> [ClipCollection] {
        try synchronized { try rows("SELECT body FROM collections").map { try decode(ClipCollection.self, $0[0]) }.sorted { ($0.position, $0.name) < ($1.position, $1.name) } }
    }
    public func saveCollection(_ collection: ClipCollection) throws {
        try synchronized { try transaction {
            guard !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopyError.invalid("集合名不能为空") }
            let body = try json(collection)
            try execute("INSERT INTO collections VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", [.text(collection.id.uuidString), .text(body)])
            try enqueue(collection.id, action: "collection", body: body)
        } }
    }
    public func deleteCollection(_ id: UUID, keepOrphansInHistory: Bool) throws {
        try synchronized { try transaction {
            let members = try rows("SELECT body FROM items WHERE collection=?", [.text(id.uuidString)]).map { try decode(ClipItem.self, $0[0]) }
            let days = try metadata(LibrarySettings.self,key:"settings")?.retentionDays ?? 30
            guard !members.contains(where:{ $0.pendingDeletion != nil }) else { throw CopyError.unavailable("集合中有可撤销删除，请先撤销或等待删除完成") }
            if keepOrphansInHistory && members.contains(where:{ !hasValidHistory($0,days:days,now:Date()) }) { throw CopyError.unavailable("集合包含仅收藏内容，请在 Copy 中选择转移或明确删除") }
            for var item in members {
                item.collectionID = nil; item.revision += 1
                if !item.inHistory && !keepOrphansInHistory { try hardDelete(item.id) }
                else { if !item.inHistory { item.inHistory = true }; try save(item) }
            }
            try execute("DELETE FROM collections WHERE id=?", [.text(id.uuidString)]); try enqueue(id, action: "deleteCollection", body: "{}")
        } }
    }
    public func requestDeletion(_ ids: [UUID], now: Date = Date()) throws {
        try synchronized { try transaction {
            for id in ids {
                guard var item = try item(id) else { continue }; item.pendingDeletion = now.addingTimeInterval(10); item.revision += 1
                // Pending removal is local until the undo period ends.
                try save(item, action: "pendingDeletion")
            }
        } }
    }
    @discardableResult public func undoDeletion(_ ids: [UUID], now: Date = Date()) throws -> Int {
        try synchronized { try transaction {
            var restored = 0
            for id in ids {
                guard var item = try item(id, includePending: true), let deadline = item.pendingDeletion, deadline > now else { continue }
                item.pendingDeletion = nil; item.revision += 1; try save(item); restored += 1
            }
            return restored
        } }
    }
    public func undoableDeletions(now: Date = Date()) throws -> [ClipItem] {
        try synchronized { try rows("SELECT body FROM items WHERE pending>?",[.text(String(now.timeIntervalSince1970))]).map { try decode(ClipItem.self,$0[0]) } }
    }
    private func hardDelete(_ id: UUID) throws {
        try execute("DELETE FROM search WHERE rowid=(SELECT rowid FROM items WHERE id=?)", [.text(id.uuidString)])
        try execute("DELETE FROM items WHERE id=?", [.text(id.uuidString)])
        try execute("DELETE FROM captures WHERE item=?", [.text(id.uuidString)])
        // Superseded payloads must not retain deleted clipboard contents indefinitely.
        try execute("DELETE FROM outbox WHERE item=?", [.text(id.uuidString)])
        try execute("INSERT OR REPLACE INTO tombstones VALUES(?,?)", [.text(id.uuidString), .text(String(Date().timeIntervalSince1970))])
        try enqueue(id, action: "delete", body: "{}")
    }
    public func maintain(retentionDays: Int, now: Date = Date()) throws {
        try synchronized {
            let previous = try metadata(Date.self, key: "lastMaintenance")
            guard previous == nil || (now >= previous!.addingTimeInterval(-300) && now <= previous!.addingTimeInterval(86400 * 7)) else { throw CopyError.unavailable("检测到时钟跳变或长时间未运行，已暂停自动清理，请确认时间") }
            var removed = false
            try transaction {
                for row in try rows("SELECT id FROM items WHERE pending IS NOT NULL AND pending<=?", [.text(String(now.timeIntervalSince1970))]) { if let id = UUID(uuidString: row[0]) { try hardDelete(id); removed = true } }
                if retentionDays > 0 {
                    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
                    for row in try rows("SELECT body FROM items WHERE history=1 AND pending IS NULL AND captured<?", [.text(String(cutoff.timeIntervalSince1970))]) {
                        var item = try decode(ClipItem.self, row[0])
                        if item.collectionID == nil { try hardDelete(item.id); removed = true }
                        else { item.inHistory = false; item.revision += 1; try save(item) }
                    }
                }
                try setMetadata(now, key: "lastMaintenance")
            }
            // Do not scan every attachment on each minute tick. Explicit destructive actions
            // collect immediately; ordinary maintenance repairs abandoned writes hourly.
            let collected = try metadata(Date.self,key:"lastAssetCollection")
            if removed || collected == nil || now.timeIntervalSince(collected!) >= 3600 {
                try collectUnreferencedAssets(); try setMetadata(now,key:"lastAssetCollection")
            }
        }
    }
    /// Commit the reviewed expiration scope and the policy together. Asset reclamation
    /// is left to maintenance, so a rollback can never remove referenced files.
    public func applyRetention(_ settings: LibrarySettings, expectedToken: String, now: Date = Date()) throws {
        try synchronized { try transaction {
            try checkReview(expectedToken)
            guard settings.retentionDays >= 0 else { throw CopyError.invalid("历史保留期无效") }
            let previous = try metadata(Date.self,key:"lastMaintenance")
            guard previous == nil || (now >= previous!.addingTimeInterval(-300) && now <= previous!.addingTimeInterval(86400*7)) else { throw CopyError.unavailable("检测到时钟跳变，请先确认时间") }
            if settings.retentionDays > 0 {
                let cutoff = now.addingTimeInterval(-Double(settings.retentionDays)*86400)
                for row in try rows("SELECT body FROM items WHERE history=1 AND pending IS NULL AND captured<?",[.text(String(cutoff.timeIntervalSince1970))]) {
                    var item = try decode(ClipItem.self,row[0])
                    if item.collectionID == nil { try hardDelete(item.id) }
                    else { item.inHistory = false; item.revision += 1; try save(item) }
                }
            }
            try setMetadata(settings,key:"settings")
            try execute("DELETE FROM metadata WHERE key='lastAssetCollection'")
        } }
    }
    public func clearHistory(expectedToken: String? = nil) throws {
        try synchronized { try transaction {
            try checkReview(expectedToken)
            for row in try rows("SELECT body FROM items WHERE history=1") {
                var item = try decode(ClipItem.self, row[0])
                if item.collectionID == nil { try hardDelete(item.id) }
                else { item.inHistory = false; item.revision += 1; try save(item) }
            }
        }; try collectUnreferencedAssets() }
    }
    public func rebuildIndex() throws {
        try synchronized { try transaction {
            try execute("DELETE FROM search")
            for row in try rows("SELECT body FROM items WHERE pending IS NULL") {
                let item = try decode(ClipItem.self, row[0]); try execute("INSERT INTO search(rowid,id,content) SELECT rowid,?,? FROM items WHERE id=?", [.text(item.id.uuidString), .text([item.title,item.text,item.ocr].joined(separator: "\n")),.text(item.id.uuidString)])
            }
        } }
    }
    public func collectUnreferencedAssets() throws {
        try synchronized { try transaction {
            var referenced = Set<String>()
            for row in try rows("SELECT body FROM items") { referenced.formUnion(try decode(ClipItem.self, row[0]).representations.map(\.digest)) }
            // BEGIN IMMEDIATE also excludes writers in App Intents / other processes.
            // Only the content-addressed files owned by this store are eligible.
            for url in try fm.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)
            where url.lastPathComponent.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil && !referenced.contains(url.lastPathComponent) { try fm.removeItem(at: url) }
        } }
    }
    public func diskUsage() throws -> Int64 {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            let r = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]); if r.isRegularFile == true { size += Int64(r.fileSize ?? 0) }
        }
        return size
    }
    public func counts() throws -> (items: Int, pending: Int) { try synchronized { (Int(try scalar("SELECT count(*) FROM items WHERE pending IS NULL")), Int(try scalar("SELECT count(*) FROM items WHERE pending IS NOT NULL"))) } }
}

public struct ExportManifest: Codable {
    public var format: Int = 1
    public var exportID: UUID
    public var created: Date
    public var items: [ClipItem]
    public var collections: [ClipCollection]
    public var missingAssets: [String]
    public var missingFileReferences: Int? = 0
    public var complete: Bool { missingAssets.isEmpty && (missingFileReferences ?? 0) == 0 }
}
extension LibraryStore {
    /// An uncompressed directory is deliberate: no hidden archive expansion or executable import hooks.
    public func export(to destination: URL, ids: Set<UUID>? = nil, includeAssets: Bool = true) throws -> ExportManifest {
        try synchronized {
            guard !fm.fileExists(atPath: destination.path) else { throw CopyError.invalid("导出目标必须是新目录") }
            let items = try rows("SELECT body FROM items WHERE pending IS NULL").map { try decode(ClipItem.self, $0[0]) }.filter { ids == nil || ids!.contains($0.id) }
            var manifest = ExportManifest(exportID: UUID(), created: Date(), items: items, collections: try collections(), missingAssets: [])
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".copy-export-\(UUID())")
            try fm.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)
            do {
                var written = Set<String>()
                for index in manifest.items.indices {
                    for repIndex in manifest.items[index].representations.indices where manifest.items[index].representations[repIndex].type == "com.copy.file-list" {
                        let portable = try FileReference.portable(data(for: manifest.items[index].representations[repIndex]),availableTypes:Set(manifest.items[index].representations.map(\.type)))
                        manifest.missingFileReferences = (manifest.missingFileReferences ?? 0) + portable.missing
                        let hash = ContentRules.digest(portable.data)
                        manifest.items[index].representations[repIndex] = Representation(type:"com.copy.file-list",digest:hash,bytes:portable.data.count)
                        if includeAssets { try portable.data.write(to: staging.appendingPathComponent("assets/\(hash)"),options:.atomic); written.insert(hash) }
                        else { manifest.missingAssets.append(hash); written.insert(hash) }
                    }
                }
                for item in manifest.items { for rep in item.representations where !written.contains(rep.digest) {
                    written.insert(rep.digest)
                    if includeAssets, let bytes = try? data(for: rep) { try bytes.write(to: staging.appendingPathComponent("assets/\(rep.digest)"), options: .atomic) }
                    else { manifest.missingAssets.append(rep.digest) }
                } }
                let pretty = JSONEncoder(); pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
                try pretty.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                try fm.moveItem(at: staging, to: destination); return manifest
            } catch { try? fm.removeItem(at: staging); throw error }
        }
    }
    public func inspectImport(from source: URL, maxBytes: Int64 = 512 * 1024 * 1024) throws -> ExportManifest {
        let url = source.appendingPathComponent("manifest.json")
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 20 * 1024 * 1024 else { throw CopyError.invalid("清单过大或为符号链接") }
        let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: url))
        guard manifest.format == 1, manifest.items.count <= 100000, manifest.missingAssets.isEmpty else { throw CopyError.invalid("格式不支持或备份附件不完整") }
        guard Set(manifest.items.map(\.id)).count == manifest.items.count, Set(manifest.collections.map(\.id)).count == manifest.collections.count else { throw CopyError.invalid("重复对象标识") }
        let collectionIDs = Set(manifest.collections.map(\.id))
        var seen = Set<String>(), total: Int64 = 0
        for item in manifest.items {
            guard item.pendingDeletion == nil, item.collectionID == nil || collectionIDs.contains(item.collectionID!) else { throw CopyError.invalid("悬空集合或待删除记录") }
            guard item.text.utf8.count <= 5 * 1024 * 1024 else { throw CopyError.invalid("文本超限") }
            for rep in item.representations {
                guard rep.digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, rep.bytes >= 0, rep.bytes <= 20 * 1024 * 1024 else { throw CopyError.invalid("附件路径或大小") }
                if seen.insert(rep.digest).inserted { total += Int64(rep.bytes) }
                guard total <= maxBytes else { throw CopyError.budget }
                let file = source.appendingPathComponent("assets/\(rep.digest)")
                let canonicalRoot = source.resolvingSymlinksInPath().path + "/assets/"
                guard file.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) else { throw CopyError.invalid("附件越过导入目录") }
                let attrs = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, attrs.fileSize == rep.bytes else { throw CopyError.invalid("附件大小或类型") }
                guard ContentRules.digest(try Data(contentsOf: file)) == rep.digest else { throw CopyError.invalid("附件校验失败") }
            }
        }
        return manifest
    }
    public func importArchive(from source: URL, budget: Int64 = 512 * 1024 * 1024) throws -> Int {
        try synchronized {
            let manifest = try inspectImport(from: source, maxBytes: budget)
            let key = "import-\(manifest.exportID.uuidString)"
            if try metadata(Bool.self, key: key) == true { return 0 }
            let reps = Dictionary(manifest.items.flatMap(\.representations).map { ($0.digest,$0) }, uniquingKeysWith: { a, _ in a })
            let needed = reps.values.filter { !fm.fileExists(atPath: assetsURL.appendingPathComponent($0.digest).path) }.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            guard try diskUsage() + needed + 65536 <= budget else { throw CopyError.budget }
            // Imported IDs never overwrite live or tombstoned IDs. The import marker and rows commit together.
            return try transaction {
                var collectionMap: [UUID: UUID] = [:]
                for var c in manifest.collections {
                    let old = c.id; c.id = UUID(); collectionMap[old] = c.id
                    try execute("INSERT INTO collections VALUES(?,?)", [.text(c.id.uuidString), .text(try json(c))])
                    try enqueue(c.id, action: "collection", body: try json(c))
                }
                for var item in manifest.items {
                    var payload: [String:Data] = [:]
                    for index in item.representations.indices {
                        let rep = item.representations[index], file = source.appendingPathComponent("assets/\(rep.digest)")
                        guard file.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/assets/") else { throw CopyError.invalid("附件路径已改变") }
                        var bytes = try Data(contentsOf:file)
                        guard bytes.count == rep.bytes, ContentRules.digest(bytes) == rep.digest else { throw CopyError.invalid("附件在校验后发生变化") }
                        if rep.type == "com.copy.file-list" { bytes = try FileReference.portable(bytes,availableTypes:Set(item.representations.map(\.type))).data }
                        let hash = ContentRules.digest(bytes), dest = assetsURL.appendingPathComponent(hash)
                        if !fm.fileExists(atPath:dest.path) { try bytes.write(to:dest,options:.atomic) }
                        item.representations[index] = Representation(type:rep.type,digest:hash,bytes:bytes.count); payload[rep.type] = bytes
                    }
                    item.fingerprint = ContentRules.fingerprint(payload)
                    item.id = UUID(); item.revision = 1; item.collectionID = item.collectionID.flatMap { collectionMap[$0] }
                    item.source = "import"; try save(item)
                }
                try setMetadata(true, key: key); return manifest.items.count
            }
        }
    }
}

public struct JournalOperation: Codable, Sendable {
    public var id: UUID
    public var requestHash: String
    public var state: String
    public var result: String?
}
extension LibraryStore {
    public func operation(_ id: UUID) throws -> JournalOperation? {
        try synchronized {
            guard let row = try rows("SELECT request,state,result FROM operations WHERE id=?", [.text(id.uuidString)]).first else { return nil }
            return JournalOperation(id: id, requestHash: row[0], state: row[1], result: row[2].isEmpty ? nil : row[2])
        }
    }
    public func registerOperation(id: UUID, requestHash: String) throws -> JournalOperation {
        try synchronized { try transaction {
            if let existing = try operation(id) { guard existing.requestHash == requestHash else { throw CopyError.conflict }; return existing }
            try execute("INSERT INTO operations VALUES(?,?,?,NULL)", [.text(id.uuidString), .text(requestHash), .text("pending")])
            return JournalOperation(id: id, requestHash: requestHash, state: "pending", result: nil)
        } }
    }
    public func commitOperation(id: UUID, requestHash: String, body: () throws -> String) throws -> JournalOperation {
        try synchronized { try transaction {
            guard let existing = try operation(id), existing.requestHash == requestHash else { throw CopyError.conflict }
            if existing.state == "committed" { return existing }
            guard existing.state == "pending" else { throw CopyError.permission }
            let result = try body()
            try execute("UPDATE operations SET state='committed',result=? WHERE id=?", [.text(result), .text(id.uuidString)])
            return JournalOperation(id: id, requestHash: requestHash, state: "committed", result: result)
        } }
    }
    public func rejectOperation(_ id: UUID) throws { try synchronized { try execute("UPDATE operations SET state='rejected' WHERE id=? AND state='pending'", [.text(id.uuidString)]) } }
    public func replaceContent(_ id: UUID, expectedRevision: Int, input: CaptureInput, budget: Int64, title: String? = nil) throws -> ClipItem {
        try synchronized { try transaction {
            guard let current = try item(id), current.revision == expectedRevision else { throw CopyError.conflict }
            try ContentRules.validate(input)
            guard try diskUsage() + Int64(input.representations.values.reduce(0) { $0 + $1.count }) + 65536 <= budget else { throw CopyError.budget }
            let reps = try input.representations.sorted(by: { $0.key < $1.key }).map { type, bytes -> Representation in
                let digest = ContentRules.digest(bytes), file = assetsURL.appendingPathComponent(ContentRules.digest(bytes))
                if !fm.fileExists(atPath: file.path) { try bytes.write(to: file, options: .atomic) }
                return Representation(type: type, digest: digest, bytes: bytes.count)
            }
            return try update(id, expectedRevision: expectedRevision) { item in item.representations = reps; item.text = input.text; item.kind = input.kind; item.ocr = ""; item.fingerprint = ContentRules.fingerprint(input.representations); if let title { item.title = title } }
        } }
    }
    public func createContent(_ input: CaptureInput, title: String, budget: Int64) throws -> ClipItem {
        try synchronized { try transaction {
            let item = try capture(input,budget:budget,deduplicate:false)
            return try update(item.id,expectedRevision:item.revision) { $0.title = title }
        } }
    }
    public func diagnostics() throws -> String {
        try synchronized {
            let counts = try counts()
            return "Copy diagnostics v1\nSchema: 2\nItems: \(counts.items)\nPending deletions: \(counts.pending)\nManaged bytes: \(try diskUsage())\nIntegrity: \(try rows("PRAGMA quick_check").first?.first == "ok" ? "ok" : "failed")\nNo clipboard content, paths, URLs, app names or credentials included.\n"
        }
    }
}

extension LibraryStore {
    public func moveItems(_ items: [ClipItem], to collectionID: UUID?) throws {
        try synchronized { try transaction {
            for item in items { _ = try update(item.id, expectedRevision:item.revision) { $0.collectionID = collectionID; $0.collectionOrder = nil } }
        } }
    }
    public func orderItems(_ ids: [UUID], in collectionID: UUID) throws {
        try synchronized { try transaction {
            guard Set(ids).count == ids.count else { throw CopyError.invalid("排序项重复") }
            for (index,id) in ids.enumerated() {
                guard let item = try item(id), item.collectionID == collectionID else { throw CopyError.conflict }
                _ = try update(id,expectedRevision:item.revision) { $0.collectionOrder = index }
            }
        } }
    }
}

private struct FileLease: Codable { var created: Date; var name: String }
extension LibraryStore {
    public func createLease(data: Data, name: String, budget: Int64, now: Date = Date()) throws -> URL {
        try synchronized {
            guard try diskUsage() + Int64(data.count) + 65536 <= budget else { throw CopyError.budget }
            guard (try root.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0) >= 1024*1024*1024 else { throw CopyError.unavailable("可用空间不足，无法创建文件副本") }
            let originalName = URL(fileURLWithPath:name).lastPathComponent
            let safeName = originalName == ".lease.json" ? "Copy-.lease.json" : originalName
            guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw CopyError.invalid("文件名") }
            let directory = root.appendingPathComponent("leases/\(UUID())",isDirectory:true)
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            do {
                let file = directory.appendingPathComponent(safeName)
                try data.write(to:file,options:.atomic)
                try encoder.encode(FileLease(created:now,name:safeName)).write(to:directory.appendingPathComponent(".lease.json"),options:.atomic)
                return file
            } catch { try? fm.removeItem(at:directory); throw error }
        }
    }
    public func collectExpiredLeases(protecting files: Set<URL>, now: Date = Date()) throws {
        try synchronized {
            let directory = root.appendingPathComponent("leases",isDirectory:true)
            guard fm.fileExists(atPath:directory.path) else { return }
            let protected = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
            for lease in try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey]) {
                guard UUID(uuidString:lease.lastPathComponent) != nil, !protected.contains(lease.standardizedFileURL), try lease.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true,
                      let bytes = try? Data(contentsOf:lease.appendingPathComponent(".lease.json")), let metadata = try? decoder.decode(FileLease.self,from:bytes), now.timeIntervalSince(metadata.created) >= 86400 else { continue }
                var coordinationError: NSError?, deletionError: Error?
                NSFileCoordinator().coordinate(writingItemAt:lease,options:.forDeleting,error:&coordinationError) { url in do { try fm.removeItem(at:url) } catch { deletionError = error } }
                if let error = coordinationError ?? deletionError as NSError? { throw error }
            }
        }
    }
}

public struct RemovalImpact: Sendable {
    public var records: Int
    public var deleted: Int
    public var collections: Int
    public var reclaimableAssetBytes: Int64
    public var reviewToken: String
}
public struct StorageUsage: Sendable {
    public var database: Int64 = 0
    public var assets: Int64 = 0
    public var leases: Int64 = 0
    public var other: Int64 = 0
    public var total: Int64 { database + assets + leases + other }
}
extension LibraryStore {
    public func storageUsage() throws -> StorageUsage {
        try synchronized {
            var usage = StorageUsage()
            guard let enumerator = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]) else { return usage }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                if url.path.hasPrefix(assetsURL.path + "/") { usage.assets += size }
                else if url.path.hasPrefix(root.appendingPathComponent("leases").path + "/") { usage.leases += size }
                else if url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path && url.lastPathComponent.hasPrefix("library.sqlite") { usage.database += size }
                else { usage.other += size }
            }
            return usage
        }
    }
    /// Snapshot for a concrete confirmation dialog. Shared asset hashes are counted only
    /// when no record outside the removal set still owns them.
    public func removalImpact(ids: Set<UUID>? = nil, historyOnly: Bool = false, collectionID: UUID? = nil, before: Date? = nil) throws -> RemovalImpact {
        try synchronized { try transaction {
            let all = try rows("SELECT body FROM items").map { try decode(ClipItem.self,$0[0]) }
            let affected = all.filter { (ids == nil || ids!.contains($0.id)) && (!historyOnly || $0.inHistory) && (collectionID == nil || $0.collectionID == collectionID) && (before == nil || $0.captured < before!) }
            let deleted = affected.filter { !historyOnly || $0.collectionID == nil }, removedIDs = Set(deleted.map(\.id))
            let keptHashes = Set(all.filter { !removedIDs.contains($0.id) }.flatMap(\.representations).map(\.digest))
            let freed = Dictionary(deleted.flatMap(\.representations).filter { !keptHashes.contains($0.digest) }.map { ($0.digest,$0.bytes) },uniquingKeysWith:{ a,_ in a }).values.reduce(Int64(0)) { $0 + Int64($1) }
            return RemovalImpact(records:affected.count,deleted:deleted.count,collections:try collections().count,reclaimableAssetBytes:freed,reviewToken:try reviewToken())
        } }
    }
    public func clearPersonalLibrary(expectedToken: String? = nil) throws {
        try synchronized {
            try transaction {
                try checkReview(expectedToken)
                for row in try rows("SELECT id FROM items") { if let id = UUID(uuidString:row[0]) { try hardDelete(id) } }
                for collection in try collections() { try deleteCollection(collection.id,keepOrphansInHistory:false) }
                // Operation results may contain prior clipboard text. Keep only deletion
                // tombstones / outbound deletions; cloud deletion remains a separate adapter.
                try execute("DELETE FROM operations")
                try execute("DELETE FROM metadata WHERE key LIKE 'operationOwner.%'")
                try setMetadata(QueueSession(),key:"queue")
            }
            try collectUnreferencedAssets()
        }
    }
    public func removeFromHistory(_ ids: [UUID], expectedToken: String? = nil) throws {
        try synchronized {
            try transaction {
                try checkReview(expectedToken)
                for id in ids {
                    guard var item = try item(id) else { continue }
                    if item.collectionID == nil { try hardDelete(id) }
                    else { item.inHistory = false; item.revision += 1; try save(item) }
                }
            }
            try collectUnreferencedAssets()
        }
    }
    public func orderCollections(_ ids: [UUID]) throws {
        try synchronized { try transaction {
            let values = try collections()
            guard ids.count == values.count, Set(ids) == Set(values.map(\.id)) else { throw CopyError.conflict }
            for (index,id) in ids.enumerated() {
                var value = values.first { $0.id == id }!; value.position = index; try saveCollection(value)
            }
        } }
    }
}

extension LibraryStore {
    /// Restoring never replaces a live store. The new identity is committed before the
    /// staging directory is atomically published; no account, token or sync state is copied.
    public static func restoreArchive(from source: URL, to destination: URL, budget: Int64 = 512*1024*1024) throws -> LibraryStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath:destination.path) else { throw CopyError.invalid("恢复目标必须是新目录，现有资料库不会被覆盖") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".copy-restore-\(UUID())",isDirectory:true)
        do {
            var restored: LibraryStore? = try LibraryStore(root:staging)
            _ = try restored!.importArchive(from:source,budget:budget)
            var settings = LibrarySettings(); settings.budgetBytes = budget
            try restored!.setMetadata(settings,key:"settings")
            try restored!.setMetadata(QueueSession(),key:"queue")
            // Close the SQLite connection before moving the database and its WAL together.
            restored = nil
            try fm.moveItem(at:staging,to:destination)
        } catch { try? fm.removeItem(at:staging); throw error }
        return try LibraryStore(root:destination)
    }
}

public struct CollectionRemovalReview: Sendable {
    public var token: String
    public var members: Int
    public var onlyPinned: Int
    public var bytes: Int64
}
public enum CollectionRemovalMode { case keepHistory, transferOrphans(UUID), deleteOrphans, deleteAll }
public enum ItemPosition { case first, previous, next, last }
extension LibraryStore {
    private func reviewToken() throws -> String {
        // All library membership/revision changes invalidate a destructive preview, including
        // changes committed by another connection. No clipboard text is saved in the token.
        let values = try rows("SELECT id, json_extract(body,'$.revision'),history,collection,pending FROM items ORDER BY id")
        let collectionValues = try rows("SELECT id,body FROM collections ORDER BY id")
        let policy = try rows("SELECT body FROM metadata WHERE key='settings'")
        return ContentRules.digest(try encoder.encode([values,collectionValues,policy]))
    }
    private func checkReview(_ token: String?) throws {
        if let token, try token != reviewToken() { throw CopyError.unavailable("资料库在确认期间发生变化，未执行删除。请重新查看影响范围。") }
    }
    private func hasValidHistory(_ item: ClipItem, days: Int, now: Date) -> Bool {
        item.inHistory && (days == 0 || item.captured >= now.addingTimeInterval(-Double(days)*86400))
    }
    public func collectionRemovalReview(_ id: UUID, days: Int, now: Date = Date()) throws -> CollectionRemovalReview {
        try synchronized { try transaction {
            guard try collections().contains(where:{ $0.id == id }) else { throw CopyError.notFound }
            let members = try rows("SELECT body FROM items WHERE collection=?",[.text(id.uuidString)]).map { try decode(ClipItem.self,$0[0]) }
            guard !members.contains(where:{ $0.pendingDeletion != nil }) else { throw CopyError.unavailable("集合中有可撤销删除，请先撤销或等待删除完成") }
            let bytes = Dictionary(members.flatMap(\.representations).map { ($0.digest,$0.bytes) },uniquingKeysWith:{ a,_ in a }).values.reduce(Int64(0)) { $0 + Int64($1) }
            return CollectionRemovalReview(token:try reviewToken(),members:members.count,onlyPinned:members.filter { !hasValidHistory($0,days:days,now:now) }.count,bytes:bytes)
        } }
    }
    public func removeCollection(_ id: UUID, mode: CollectionRemovalMode, expectedToken: String, days: Int, now: Date = Date()) throws {
        try synchronized {
            try transaction {
                try checkReview(expectedToken)
                let review = try collectionRemovalReview(id,days:days,now:now)
                if case .keepHistory = mode, review.onlyPinned > 0 { throw CopyError.unavailable("仅收藏内容需要转移或明确删除") }
                if case .transferOrphans(let destination) = mode {
                    guard destination != id, try collections().contains(where:{ $0.id == destination }) else { throw CopyError.notFound }
                }
                for row in try rows("SELECT body FROM items WHERE collection=?",[.text(id.uuidString)]) {
                    var item = try decode(ClipItem.self,row[0]); let valid = hasValidHistory(item,days:days,now:now)
                    switch mode {
                    case .deleteAll: try hardDelete(item.id); continue
                    case .deleteOrphans where !valid: try hardDelete(item.id); continue
                    case .transferOrphans(let destination) where !valid: item.collectionID = destination; item.collectionOrder = nil; item.inHistory = false
                    default: item.collectionID = nil; item.collectionOrder = nil
                    }
                    item.revision += 1; try save(item)
                }
                try execute("DELETE FROM collections WHERE id=?",[.text(id.uuidString)]); try enqueue(id,action:"deleteCollection",body:"{}")
            }
            try collectUnreferencedAssets()
        }
    }
    public func unpin(_ ids: [UUID], expectedToken: String, days: Int, now: Date = Date()) throws -> [UUID] {
        try synchronized { try transaction {
            try checkReview(expectedToken); var pending: [UUID] = []
            for id in ids {
                guard var item = try item(id), item.collectionID != nil else { continue }
                if !hasValidHistory(item,days:days,now:now) {
                    // Keep membership until deletion commits, so undo restores its only home.
                    try requestDeletion([id],now:now); pending.append(id)
                } else { item.collectionID = nil; item.collectionOrder = nil; item.revision += 1; try save(item) }
            }
            return pending
        } }
    }
    public func repositionItem(_ id: UUID, expectedRevision: Int, position: ItemPosition) throws {
        try synchronized { try transaction {
            guard let item = try item(id), item.revision == expectedRevision, let collection = item.collectionID else { throw CopyError.conflict }
            var members = try rows("SELECT body FROM items WHERE collection=? AND pending IS NULL ORDER BY COALESCE(json_extract(body,'$.collectionOrder'),2147483647),captured DESC,id ASC",[.text(collection.uuidString)]).map { try decode(ClipItem.self,$0[0]) }
            guard let from = members.firstIndex(where:{ $0.id == id }) else { throw CopyError.notFound }
            let to: Int
            switch position { case .first: to = 0; case .previous: to = max(0,from-1); case .next: to = min(members.count-1,from+1); case .last: to = members.count-1 }
            guard from != to else { return }
            members.insert(members.remove(at:from),at:to)
            for (index,var member) in members.enumerated() where member.collectionOrder != index {
                member.collectionOrder = index; member.revision += 1; try save(member)
            }
        } }
    }
}

extension LibraryStore {
    public func unpinReview(_ ids: [UUID], days: Int, now: Date = Date()) throws -> CollectionRemovalReview {
        try synchronized { try transaction {
            let values = try ids.compactMap { try item($0) }.filter { $0.collectionID != nil }
            let bytes = Dictionary(values.flatMap(\.representations).map { ($0.digest,$0.bytes) },uniquingKeysWith:{ a,_ in a }).values.reduce(Int64(0)) { $0 + Int64($1) }
            return CollectionRemovalReview(token:try reviewToken(),members:values.count,onlyPinned:values.filter { !hasValidHistory($0,days:days,now:now) }.count,bytes:bytes)
        } }
    }
}
