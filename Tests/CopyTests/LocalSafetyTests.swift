import XCTest
import CopyCore
import CopyStorage

final class LocalSafetyTests: XCTestCase {
    var root: URL!
    var store: LibraryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-local-safety-\(UUID())"); store = try LibraryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at:root) }
    func text(_ value: String, daysAgo: Int = 0) throws -> ClipItem {
        try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data(value.utf8)],text:value),now:Date().addingTimeInterval(-Double(daysAgo)*86400))
    }
    func pin(_ item: ClipItem, _ collection: ClipCollection) throws -> ClipItem { try store.update(item.id,expectedRevision:item.revision) { $0.collectionID = collection.id } }
    func testClearReviewRejectsAnotherConnectionsNewContent() throws {
        let first = try text("reviewed")
        let review = try store.removalImpact(historyOnly:true)
        let other = try LibraryStore(root:root)
        let second = try other.capture(CaptureInput(representations:["public.utf8-plain-text":Data("new".utf8)],text:"new"))
        XCTAssertThrowsError(try store.clearHistory(expectedToken:review.reviewToken))
        XCTAssertThrowsError(try store.clearPersonalLibrary(expectedToken:review.reviewToken))
        XCTAssertThrowsError(try store.removeFromHistory([first.id],expectedToken:review.reviewToken))
        XCTAssertNotNil(try store.item(first.id)); XCTAssertNotNil(try store.item(second.id))
        try store.clearHistory(expectedToken:store.removalImpact(historyOnly:true).reviewToken)
        XCTAssertEqual(try store.counts().items,0)
    }
    func testUnpinExpiredHistoryKeepsOriginalMembershipForUndo() throws {
        let c = ClipCollection(name:"only home"); try store.saveCollection(c)
        let old = try pin(text("expired",daysAgo:40),c), recent = try pin(text("recent"),c)
        let now = Date(), review = try store.unpinReview([old.id,recent.id],days:30,now:now)
        XCTAssertEqual(review.onlyPinned,1)
        let pending = try store.unpin([old.id,recent.id],expectedToken:review.token,days:30,now:now)
        XCTAssertEqual(pending,[old.id]); XCTAssertNil(try store.item(old.id))
        XCTAssertNil(try XCTUnwrap(store.item(recent.id)).collectionID)
        XCTAssertThrowsError(try store.collectionRemovalReview(c.id,days:30,now:now))
        XCTAssertEqual(try store.undoDeletion(pending,now:now.addingTimeInterval(5)),1)
        XCTAssertEqual(try store.item(old.id)?.collectionID,c.id)
    }
    func testCollectionRemovalTransfersOnlyOrphansWithoutRevivingHistory() throws {
        let source = ClipCollection(name:"source"), target = ClipCollection(name:"target")
        try store.saveCollection(source); try store.saveCollection(target)
        let old = try pin(text("expired",daysAgo:40),source), current = try pin(text("current"),source)
        let review = try store.collectionRemovalReview(source.id,days:30)
        XCTAssertEqual(review.onlyPinned,1)
        XCTAssertThrowsError(try store.removeCollection(source.id,mode:.keepHistory,expectedToken:review.token,days:30))
        XCTAssertThrowsError(try store.deleteCollection(source.id,keepOrphansInHistory:true))
        try store.removeCollection(source.id,mode:.transferOrphans(target.id),expectedToken:review.token,days:30)
        XCTAssertEqual(try store.item(old.id)?.collectionID,target.id); XCTAssertEqual(try store.item(old.id)?.inHistory,false)
        XCTAssertNil(try store.item(current.id)?.collectionID); XCTAssertEqual(try store.item(current.id)?.inHistory,true)
        XCTAssertEqual(try store.collections().map(\.id),[target.id])
    }
    func testExplicitCollectionDeletionDoesNotDeleteValidHistory() throws {
        let c = ClipCollection(name:"scope"); try store.saveCollection(c)
        let old = try pin(text("old",daysAgo:40),c), recent = try pin(text("recent"),c)
        let review = try store.collectionRemovalReview(c.id,days:30)
        try store.removeCollection(c.id,mode:.deleteOrphans,expectedToken:review.token,days:30)
        XCTAssertNil(try store.item(old.id)); XCTAssertNotNil(try store.item(recent.id))
    }
    func testRetentionReviewRejectsConcurrentChangesAndCommitsPolicyWithDeletion() throws {
        let old = try text("expires",daysAgo:10)
        var settings = LibrarySettings(); settings.retentionDays = 7
        let now = Date(), review = try store.removalImpact(historyOnly:true,before:now.addingTimeInterval(-7*86400))
        let other = try LibraryStore(root:root)
        _ = try other.update(old.id,expectedRevision:old.revision) { $0.title = "concurrent" }
        XCTAssertThrowsError(try store.applyRetention(settings,expectedToken:review.reviewToken,now:now))
        XCTAssertNotNil(try store.item(old.id)); XCTAssertNil(try store.metadata(LibrarySettings.self,key:"settings"))
        let fresh = try store.removalImpact(historyOnly:true,before:now.addingTimeInterval(-7*86400))
        try store.applyRetention(settings,expectedToken:fresh.reviewToken,now:now)
        XCTAssertNil(try store.item(old.id)); XCTAssertEqual(try store.metadata(LibrarySettings.self,key:"settings")?.retentionDays,7)
    }
    func testReorderSpansPagesAndRejectsStaleRevision() throws {
        let c = ClipCollection(name:"paging"); try store.saveCollection(c)
        var ids: [UUID] = []
        for n in 0..<62 { ids.append(try pin(text("row \(n)"),c).id) }
        let last = try XCTUnwrap(store.item(ids[0]))
        try store.repositionItem(last.id,expectedRevision:last.revision,position:.first)
        var query = SearchQuery(collectionID:c.id,historyOnly:false); query.limit = 1000
        var items = try store.search(query)
        XCTAssertEqual(items.first?.id,last.id); XCTAssertEqual(Set(items.map(\.id)),Set(ids))
        XCTAssertThrowsError(try store.repositionItem(last.id,expectedRevision:last.revision,position:.last))
        let fresh = try XCTUnwrap(store.item(last.id))
        try store.repositionItem(fresh.id,expectedRevision:fresh.revision,position:.last)
        items = try store.search(query); XCTAssertEqual(items.last?.id,last.id)
        XCTAssertEqual(items.compactMap(\.collectionOrder),Array(0..<62))
    }
}
