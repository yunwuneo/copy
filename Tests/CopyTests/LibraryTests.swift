import XCTest
import CopyCore
import CSQLite
@testable import CopyStorage

final class LibraryTests: XCTestCase {
    var root: URL!
    var store: LibraryStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-tests-\(UUID())")
        store = try LibraryStore(root: root)
    }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: root) }
    func input(_ text: String, source: String? = nil) -> CaptureInput { CaptureInput(representations: ["public.utf8-plain-text": Data(text.utf8)], text: text, source: source) }
    func testChineseSearchAndFiltering() throws {
        let first = try store.capture(input("项目剪切板与产品规格", source: "test.one"))
        _ = try store.capture(input("unrelated", source: "test.two"))
        XCTAssertEqual(try store.search(SearchQuery(text: "剪切板")).map(\.id), [first.id])
        XCTAssertEqual(try store.search(SearchQuery(text: "规格")).map(\.id), [first.id])
        var q = SearchQuery(text: "剪切板"); q.sources = ["test.two"]
        XCTAssertTrue(try store.search(q).isEmpty)
        q.sources = ["test.one", "test.two"]; q.kinds = [.image]
        XCTAssertTrue(try store.search(q).isEmpty)
    }
    func testFullRepresentationDedupAndRealRecapture() throws {
        let a = try store.capture(input("same"))
        let b = try store.capture(input("same"))
        XCTAssertEqual(a.id,b.id); XCTAssertEqual(b.captureCount,2)
        var rich = input("same"); rich.representations["public.rtf"] = Data("{\\rtf1 same}".utf8)
        XCTAssertNotEqual(try store.capture(rich).id,a.id)
        try store.requestDeletion([a.id], now: Date(timeIntervalSince1970: 1))
        try store.maintain(retentionDays: 0)
        XCTAssertNotEqual(try store.capture(input("same")).id,a.id)
    }
    func testConfidentialRejectedBeforeAssets() throws {
        var value = input("secret"); value.representations["org.nspasteboard.ConcealedType"] = Data()
        XCTAssertThrowsError(try store.capture(value))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsURL.path).count,0)
    }
    func testDeletionUndoAndPersistentDeadline() throws {
        let now = Date(), item = try store.capture(input("delete me"))
        try store.requestDeletion([item.id], now: now)
        XCTAssertTrue(try store.search(SearchQuery()).isEmpty)
        try store.undoDeletion([item.id], now: now.addingTimeInterval(5))
        XCTAssertNotNil(try store.item(item.id))
        try store.requestDeletion([item.id], now: now)
        store = nil; store = try LibraryStore(root: root)
        try store.maintain(retentionDays: 0, now: now.addingTimeInterval(11))
        XCTAssertNil(try store.item(item.id, includePending: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsURL.path).count,0)
    }
    func testPinnedRetentionAndClearHistory() throws {
        let old = Date().addingTimeInterval(-86400 * 40)
        let a = try store.capture(input("pinned"), now: old), b = try store.capture(input("expire"), now: old)
        let c = ClipCollection(name: "Keep"); try store.saveCollection(c)
        _ = try store.update(a.id, expectedRevision: a.revision) { $0.collectionID = c.id }
        try store.maintain(retentionDays: 30)
        XCTAssertNil(try store.item(b.id)); XCTAssertFalse(try XCTUnwrap(store.item(a.id)).inHistory)
        XCTAssertEqual(try store.search(SearchQuery(collectionID: c.id, historyOnly: false)).count,1)
        try store.clearHistory(); XCTAssertNotNil(try store.item(a.id))
    }
    func testEditConflictAndIndexRebuild() throws {
        let a = try store.capture(input("original"))
        _ = try store.editText(a.id, expectedRevision: a.revision, title: "新标题", text: "changed")
        XCTAssertThrowsError(try store.editText(a.id, expectedRevision: a.revision, title: "stale", text: "lost"))
        try store.rebuildIndex()
        XCTAssertTrue(try store.search(SearchQuery(text: "original")).isEmpty)
        XCTAssertEqual(try store.search(SearchQuery(text: "新标题")).count,1)
    }
    func testBudgetRejectsBeforeCommitAndAssetIntegrity() throws {
        XCTAssertThrowsError(try store.capture(input("large"), budget: 1))
        XCTAssertEqual(try store.counts().items,0)
        let a = try store.capture(input("verify")), rep = try XCTUnwrap(a.representations.first)
        try Data("corrupted".utf8).write(to: store.assetsURL.appendingPathComponent(rep.digest))
        XCTAssertThrowsError(try store.data(for: rep))
    }
    func testClockRollbackPausesExpiry() throws {
        try store.maintain(retentionDays: 30)
        XCTAssertThrowsError(try store.maintain(retentionDays: 30, now: Date().addingTimeInterval(-600)))
    }
    func testColorRulesAndQueueUncertainty() throws {
        XCTAssertEqual(ContentRules.kind(types: [], text: "#ff0088"),.color)
        XCTAssertEqual(ContentRules.kind(types: [], text: "123456"),.text)
        XCTAssertEqual(ContentRules.kind(types: [], text: "#FFF"),.text)
        var q = QueueSession(); q.ids = [UUID(),UUID()]; q.arm()
        _ = try q.begin(); XCTAssertThrowsError(try q.begin()); q.uncertain()
        XCTAssertEqual(q.cursor,0); XCTAssertThrowsError(try q.begin()); q.restore(); XCTAssertEqual(q.state,.unknown)
    }
    func testHalfOpenDates() throws {
        let date = Date(timeIntervalSince1970: 100000), a = try store.capture(input("boundary"), now: date)
        var q = SearchQuery(); q.from = date; q.before = date.addingTimeInterval(1)
        XCTAssertEqual(try store.search(q).map(\.id), [a.id]); q.before = date
        XCTAssertTrue(try store.search(q).isEmpty)
    }
}

extension LibraryTests {
    func testArchiveRoundTripIdempotencyAndNoOverwrite() throws {
        let item = try store.capture(input("可迁移 original"))
        let archive = root.appendingPathComponent("export")
        let manifest = try store.export(to: archive)
        XCTAssertTrue(manifest.complete)
        XCTAssertEqual(try store.importArchive(from: archive),1)
        XCTAssertEqual(try store.importArchive(from: archive),0)
        XCTAssertEqual(try store.counts().items,2)
        XCTAssertEqual(try store.item(item.id)?.revision,1)
    }
    func testImportRejectsTraversalAndTampering() throws {
        _ = try store.capture(input("archive")); let archive = root.appendingPathComponent("export")
        var manifest = try store.export(to: archive)
        manifest.items[0].representations[0].digest = "../escape"
        try JSONEncoder().encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.inspectImport(from: archive))
        XCTAssertEqual(try store.counts().items,1)
    }
    func testOperationAtomicityAndIdempotency() throws {
        let id = UUID(), hash = "request-one"
        _ = try store.registerOperation(id: id, requestHash: hash)
        XCTAssertThrowsError(try store.registerOperation(id: id, requestHash: "other"))
        XCTAssertThrowsError(try store.commitOperation(id: id, requestHash: hash) {
            _ = try store.capture(input("rolled back")); throw CopyError.invalid("injected failure")
        })
        XCTAssertEqual(try store.counts().items,0)
        XCTAssertEqual(try store.operation(id)?.state,"pending")
        let first = try store.commitOperation(id: id, requestHash: hash) { try store.capture(input("once")).id.uuidString }
        let second = try store.commitOperation(id: id, requestHash: hash) { XCTFail("must not execute twice"); return "bad" }
        XCTAssertEqual(first.result,second.result); XCTAssertEqual(try store.counts().items,1)
    }
    func testForwardClockJumpStopsDeletion() throws {
        let now = Date(); _ = try store.capture(input("preserved"), now: now)
        try store.maintain(retentionDays: 1, now: now)
        XCTAssertThrowsError(try store.maintain(retentionDays: 1, now: now.addingTimeInterval(86400*100)))
        XCTAssertEqual(try store.counts().items,1)
    }
}

extension LibraryTests {
    func testPortableFileReferenceHasNoBookmarkAndReportsMissingContent() throws {
        let refs = [FileReference(name:"private.txt",bookmark:Data("opaque local permission".utf8),status:"仅引用")]
        let encoded = try JSONEncoder().encode(refs)
        _ = try store.capture(CaptureInput(representations:["com.copy.file-list":encoded],text:"private.txt",kind:.files))
        let archive = root.appendingPathComponent("export"), manifest = try store.export(to:archive)
        XCTAssertFalse(manifest.complete); XCTAssertEqual(manifest.missingFileReferences,1)
        let rep = manifest.items[0].representations[0]
        let exported = try JSONDecoder().decode([FileReference].self,from:Data(contentsOf:archive.appendingPathComponent("assets/\(rep.digest)")))
        XCTAssertNil(exported[0].bookmark)
        XCTAssertEqual(try store.importArchive(from:archive),1)
    }
    func testBulkMoveIsAtomicOnStaleRevision() throws {
        let a = try store.capture(input("a")), b = try store.capture(input("b")), c = ClipCollection(name:"destination")
        try store.saveCollection(c); _ = try store.update(b.id,expectedRevision:b.revision) { $0.title = "newer" }
        XCTAssertThrowsError(try store.moveItems([a,b],to:c.id))
        XCTAssertNil(try store.item(a.id)?.collectionID)
    }
    func testQueueCrashRequiresExplicitReconciliation() throws {
        var q = QueueSession(); q.ids = [UUID(),UUID()]; q.arm(); _ = try q.begin()
        var restored = try JSONDecoder().decode(QueueSession.self,from:JSONEncoder().encode(q)); restored.restore(); restored.arm()
        XCTAssertEqual(restored.state,.unknown); XCTAssertEqual(restored.cursor,0); XCTAssertThrowsError(try restored.begin())
        restored.resolveUnknown(wasDelivered:true); XCTAssertEqual(restored.cursor,1); XCTAssertEqual(restored.state,.paused)
    }
    func testExplicitCreateDoesNotMoveExistingDuplicate() throws {
        let a = try store.capture(input("same")), b = try store.capture(input("same"),deduplicate:false)
        XCTAssertNotEqual(a.id,b.id); XCTAssertEqual(try store.counts().items,2)
    }
}

extension LibraryTests {
    func testLeaseExpirationProtectsActiveFilesAndPreservesBytes() throws {
        let now = Date(), payload = Data("leased bytes".utf8)
        let file = try store.createLease(data:payload,name:".lease.json",budget:512*1024*1024,now:now)
        XCTAssertEqual(try Data(contentsOf:file),payload)
        try store.collectExpiredLeases(protecting:[file],now:now.addingTimeInterval(86401))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        try store.collectExpiredLeases(protecting:[],now:now.addingTimeInterval(86401))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testCursorIsStableWhenNewItemsArrive() throws {
        var ids: [UUID] = []
        for n in 0..<5 { ids.append(try store.capture(input("cursor \(n)"),now:Date(timeIntervalSince1970:Double(n))).id) }
        var query = SearchQuery(text:"cursor"); query.limit = 2; query.useCollectionOrder = false
        let first = try store.search(query); XCTAssertEqual(first.map(\.id),[ids[4],ids[3]])
        _ = try store.capture(input("cursor new"),now:Date(timeIntervalSince1970:100))
        query.cursor = SearchCursor(captured:first[1].captured,id:first[1].id)
        XCTAssertEqual(try store.search(query).map(\.id),[ids[2],ids[1]])
    }
}

extension LibraryTests {
    func testRemovalImpactPreservesSharedAssetAndClearsPersonalContent() throws {
        let a = try store.capture(input("shared"),deduplicate:false)
        var b = try store.capture(input("shared"),deduplicate:false)
        let collection = ClipCollection(name:"Pinned"); try store.saveCollection(collection)
        b = try store.update(b.id,expectedRevision:b.revision) { $0.collectionID = collection.id }
        let impact = try store.removalImpact(historyOnly:true)
        XCTAssertEqual(impact.records,2); XCTAssertEqual(impact.deleted,1); XCTAssertEqual(impact.reclaimableAssetBytes,0)
        try store.removeFromHistory([a.id,b.id])
        XCTAssertNil(try store.item(a.id)); XCTAssertFalse(try XCTUnwrap(store.item(b.id)).inHistory)
        XCTAssertEqual(try store.data(for:b.representations[0]),Data("shared".utf8))
        let id = UUID(); _ = try store.registerOperation(id:id,requestHash:"x")
        _ = try store.commitOperation(id:id,requestHash:"x") { "sensitive-result" }
        try store.setMetadata(UUID(),key:"operationOwner.\(id)")
        try store.clearPersonalLibrary()
        XCTAssertEqual(try store.counts().items,0); XCTAssertTrue(try store.collections().isEmpty)
        XCTAssertNil(try store.operation(id)); XCTAssertNil(try store.metadata(UUID.self,key:"operationOwner.\(id)"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:store.assetsURL,includingPropertiesForKeys:nil).isEmpty)
        XCTAssertEqual(try store.metadata(QueueSession.self,key:"queue")?.state,.paused)
    }
    func testCollectionOrderingRejectsIncompleteSnapshot() throws {
        let a = ClipCollection(name:"A"), b = ClipCollection(name:"B")
        try store.saveCollection(a); try store.saveCollection(b)
        try store.orderCollections([b.id,a.id]); XCTAssertEqual(try store.collections().map(\.id),[b.id,a.id])
        XCTAssertThrowsError(try store.orderCollections([a.id]))
        XCTAssertEqual(try store.collections().map(\.id),[b.id,a.id])
    }
    func testAssetCollectionAcrossConnectionsRetainsCommittedUpdates() throws {
        let second = try LibraryStore(root:root)
        let item = try store.capture(input("before"))
        let changed = try second.editText(item.id,expectedRevision:item.revision,title:"edited",text:"after")
        let unknown = store.assetsURL.appendingPathComponent("not-owned.txt")
        try Data("preserve".utf8).write(to:unknown)
        try store.collectUnreferencedAssets()
        XCTAssertEqual(try store.data(for:changed.representations[0]),Data("after".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:unknown.path))
        XCTAssertThrowsError(try store.data(for:item.representations[0]))
        let usage = try store.storageUsage(); XCTAssertGreaterThan(usage.database,0); XCTAssertEqual(usage.total,try store.diskUsage())
    }
    func testPortableReferenceCannotClaimMissingSnapshotExists() throws {
        let reference = FileReference(name:"sample.txt",snapshotType:"com.copy.missing",status:"已保存快照")
        let portable = try FileReference.portable(JSONEncoder().encode([reference]),availableTypes:[])
        XCTAssertEqual(portable.missing,1)
        XCTAssertNil(try JSONDecoder().decode([FileReference].self,from:portable.data).first?.snapshotType)
    }
}

extension LibraryTests {
    func testRestoreUsesNewIdentityAndDisablesCapabilities() throws {
        _ = try store.capture(input("restore synthetic"))
        var settings = LibrarySettings(); settings.captureEnabled = true; settings.syncEnabled = true; settings.suggestionsEnabled = true
        try store.setMetadata(settings,key:"settings")
        let archive = root.appendingPathComponent("export"), destination = root.appendingPathComponent("restored")
        _ = try store.export(to:archive)
        let restored = try LibraryStore.restoreArchive(from:archive,to:destination)
        XCTAssertEqual(try restored.counts().items,1)
        XCTAssertNotEqual(try restored.metadata(UUID.self,key:"libraryID"),try store.metadata(UUID.self,key:"libraryID"))
        let config = try XCTUnwrap(restored.metadata(LibrarySettings.self,key:"settings"))
        XCTAssertFalse(config.captureEnabled); XCTAssertFalse(config.syncEnabled); XCTAssertFalse(config.suggestionsEnabled)
        XCTAssertEqual(try store.counts().items,1)
        XCTAssertThrowsError(try LibraryStore.restoreArchive(from:archive,to:destination))
        XCTAssertEqual(try restored.counts().items,1)
    }
}

extension LibraryTests {
    private func executeFixtureSQL(_ sql: String, file: URL? = nil) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open((file ?? root.appendingPathComponent("library.sqlite")).path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
    }
    func testVersionOneMigrationRebuildsRowMappingAndReleasesCheckpoint() throws {
        let item = try store.capture(input("migration synthetic 中文")); store = nil
        try executeFixtureSQL("UPDATE search SET rowid=99; PRAGMA user_version=1")
        store = try LibraryStore(root:root)
        XCTAssertEqual(try store.search(SearchQuery(text:"migration")).map(\.id),[item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("migration-recovery-v1.sqlite").path))
    }
    func testMigrationFailureKeepsOldDatabaseAndRecoverySnapshot() throws {
        _ = try store.capture(input("migration must survive")); store = nil
        try executeFixtureSQL("DROP TABLE search; CREATE TABLE search(wrong_column TEXT); PRAGMA user_version=1")
        XCTAssertThrowsError(try LibraryStore(root:root))
        let checkpoint = root.appendingPathComponent("migration-recovery-v1.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath:checkpoint.path))
        for file in [root.appendingPathComponent("library.sqlite"),checkpoint] {
            var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path,&db),SQLITE_OK)
            var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT count(*) FROM items",-1,&statement,nil),SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement,0),1)
            sqlite3_finalize(statement)
            XCTAssertEqual(sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,nil),SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement,0),1)
            sqlite3_finalize(statement); sqlite3_close(db)
        }
    }
}
