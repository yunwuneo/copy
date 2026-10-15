import XCTest
import Foundation
import CopyCore
import CopyStorage
import CSQLite

final class PerformanceTests: XCTestCase {
    func testSearchAt100000Rows() throws {
        guard ProcessInfo.processInfo.environment["COPY_PERF"] == "1" else { throw XCTSkip("显式设置 COPY_PERF=1 才创建 10 万行临时搜索样本；结束即删除") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try LibraryStore(root:root)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db,"BEGIN",nil,nil,nil)
        var row: OpaquePointer?, fts: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO items VALUES(?,?,?,1,NULL,'text',NULL,NULL,?)",-1,&row,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO search VALUES(?,?)",-1,&fts,nil),SQLITE_OK)
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self), encoder = JSONEncoder()
        defer { sqlite3_finalize(row); sqlite3_finalize(fts) }
        for index in 0..<100000 {
            let text = "剪切板性能样本 \(index) topic\(index % 100) payload text", item = ClipItem(kind:.text,text:text,representations:[],fingerprint:"fixture-\(index)",now:Date(timeIntervalSince1970:Double(index)))
            let body = String(decoding:try encoder.encode(item),as:UTF8.self)
            sqlite3_bind_text(row,1,item.id.uuidString,-1,transient); sqlite3_bind_text(row,2,item.fingerprint,-1,transient); sqlite3_bind_double(row,3,Double(index)); sqlite3_bind_text(row,4,body,-1,transient)
            XCTAssertEqual(sqlite3_step(row),SQLITE_DONE); sqlite3_reset(row)
            sqlite3_bind_text(fts,1,item.id.uuidString,-1,transient); sqlite3_bind_text(fts,2,text,-1,transient)
            XCTAssertEqual(sqlite3_step(fts),SQLITE_DONE); sqlite3_reset(fts)
        }
        XCTAssertEqual(sqlite3_exec(db,"COMMIT",nil,nil,nil),SQLITE_OK)
        var elapsed: [Double] = []
        for term in ["剪切板","topic42","99999","样本", "no-result"] {
            for _ in 0..<10 {
                let start = ContinuousClock.now
                let results = try store.search(SearchQuery(text:term))
                let components = start.duration(to:.now).components
                elapsed.append(Double(components.seconds)*1000 + Double(components.attoseconds)/1e15)
                if term == "99999" { XCTAssertEqual(results.count,1) }
            }
        }
        elapsed.sort(); let p95 = elapsed[Int(Double(elapsed.count-1)*0.95)]
        print("COPY_PERF rows=100000 queries=50 p95_ms=\(String(format:"%.2f",p95)) disk_bytes=\(try store.diskUsage())")
        XCTAssertLessThan(p95,200,"仅合成数据库搜索性能；不代表 UI、采集或 24 小时耐久验收")
    }
}
