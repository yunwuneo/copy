import XCTest
import AppKit
import CopyCore
import CopyStorage
@testable import CopyMac

final class MacIntegrationTests: XCTestCase {
    @MainActor func testNamedPasteboardRichTextRoundTripAndConcealment() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let original = NSPasteboardItem(); original.setString("中文 table", forType:.string); original.setData(Data("{\\rtf1 table}".utf8),forType:.rtf)
        board.writeObjects([original])
        let input = try XCTUnwrap(ClipboardDriver.read(board))
        XCTAssertEqual(input.kind,.richText); XCTAssertEqual(input.text,"中文 table"); XCTAssertEqual(input.representations["public.rtf"],Data("{\\rtf1 table}".utf8)); XCTAssertGreaterThanOrEqual(input.representations.count,2)
        let hidden = NSPasteboardItem(); hidden.setString("never store",forType:.string); hidden.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([hidden]); XCTAssertNil(try ClipboardDriver.read(board))
    }
    @MainActor func testMultiplePasteboardItemsPreservePayloads() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let a = NSPasteboardItem(); a.setString("first",forType:.string)
        let b = NSPasteboardItem(); b.setString("second",forType:.string)
        board.writeObjects([a,b]); let input = try XCTUnwrap(ClipboardDriver.read(board))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-mac-tests-\(UUID())"); defer { try? FileManager.default.removeItem(at:root) }
        let store = try LibraryStore(root:root), item = try store.capture(input)
        let writers = try ClipboardDriver.writers([item],store:store,plain:false,separator:"\n")
        board.clearContents(); board.writeObjects(writers)
        XCTAssertEqual(board.pasteboardItems?.compactMap { $0.string(forType:.string) },["first","second"])
    }
    @MainActor func testMCPScopesApprovalRevokeAndIdempotency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-mcp-tests-\(UUID())"); defer { try? FileManager.default.removeItem(at:root) }
        let store = try LibraryStore(root:root), service = MCPService(store:store)
        let allowed = ClipCollection(name:"Allowed"), forbidden = ClipCollection(name:"Private")
        try store.saveCollection(allowed); try store.saveCollection(forbidden)
        let item = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data("secret".utf8)],text:"secret"))
        _ = try store.update(item.id,expectedRevision:item.revision) { $0.collectionID = forbidden.id }
        let client = ClientGrant(name:"Synthetic",collections:[allowed.id],history:false,scopes:["search.metadata","items.read","items.create"])
        service.clients = [client]; service.tokenLookup = { $0 == client.id ? "synthetic-token" : nil }
        func call(_ tool: String,_ args: [String:Any]) throws -> [String:Any] {
            let body = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":tool,"arguments":args]])
            let (code,data) = service.handle(headers:["authorization":"Bearer synthetic-token","mcp-protocol-version":"2025-11-25"],payload:body)
            XCTAssertEqual(code,200); return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        }
        let denied = try call("get_item",["itemID":item.id.uuidString]); XCTAssertEqual((denied["result"] as? [String:Any])?["isError"] as? Bool,true)
        let operation = UUID().uuidString
        _ = try call("create_item",["operationID":operation,"text":"new","collectionID":allowed.id.uuidString])
        XCTAssertEqual(try store.counts().items,1); XCTAssertEqual(service.proposals.count,1)
        service.approve(try XCTUnwrap(service.proposals.first),budget:512*1024*1024)
        XCTAssertEqual(try store.counts().items,2)
        _ = try call("create_item",["operationID":operation,"text":"new","collectionID":allowed.id.uuidString]); XCTAssertEqual(service.proposals.count,0); XCTAssertEqual(try store.counts().items,2)
        _ = try call("create_item",["operationID":UUID().uuidString,"text":"revoked","collectionID":allowed.id.uuidString])
        let pending = try XCTUnwrap(service.proposals.first); service.clients = []
        service.approve(pending,budget:512*1024*1024); XCTAssertEqual(try store.counts().items,2)
    }
}

extension MacIntegrationTests {
    @MainActor func testLoopbackHTTPAuthenticationAndOriginDefense() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-http-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try LibraryStore(root:root), service = MCPService(store:store)
        let client = ClientGrant(name:"Wire test",collections:[],history:true,scopes:["search.metadata"])
        service.clients = [client]; service.tokenLookup = { $0 == client.id ? "wire-test-token" : nil }
        service.start(); defer { service.stop() }
        for _ in 0..<100 { if service.running { break }; try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertTrue(service.running,service.status); guard service.running else { return }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 3; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(service.port)/mcp")!)
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("application/json, text/event-stream",forHTTPHeaderField:"Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-11-25","capabilities":[:],"clientInfo":["name":"synthetic","version":"1"]]])
        let (_,unauthorized) = try await session.data(for:request); XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode,401)
        request.setValue("Bearer wire-test-token",forHTTPHeaderField:"Authorization")
        let (data,valid) = try await session.data(for:request); XCTAssertEqual((valid as? HTTPURLResponse)?.statusCode,200)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); XCTAssertEqual((response["result"] as? [String:Any])?["protocolVersion"] as? String,"2025-11-25")
        request.setValue("https://untrusted.example",forHTTPHeaderField:"Origin")
        let (_,origin) = try await session.data(for:request); XCTAssertEqual((origin as? HTTPURLResponse)?.statusCode,403)
    }
}

extension MacIntegrationTests {
    @MainActor func testLocalVisionOCRSyntheticImage() throws {
        let image = NSImage(size:NSSize(width:600,height:100))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:600,height:100).fill()
        ("Copy OCR 123" as NSString).draw(at:NSPoint(x:20,y:30),withAttributes:[.font:NSFont.systemFont(ofSize:38),.foregroundColor:NSColor.black])
        image.unlockFocus()
        let text = try OCRService.recognize(XCTUnwrap(image.tiffRepresentation))
        XCTAssertTrue(text.contains("123"),text)
    }
}

extension MacIntegrationTests {
    @MainActor func testMCPAttachmentChunksAndPortableReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-chunk-tests-\(UUID())"); defer { try? FileManager.default.removeItem(at:root) }
        let store = try LibraryStore(root:root), service = MCPService(store:store)
        let refs = try JSONEncoder().encode([FileReference(name:"example",bookmark:Data("private bookmark".utf8),status:"reference")])
        let item = try store.capture(CaptureInput(representations:["com.copy.file-list":refs],text:"example",kind:.files))
        let client = ClientGrant(name:"Read chunks",collections:[],history:true,scopes:["items.read"])
        service.clients = [client]; service.tokenLookup = { _ in "synthetic" }
        func get(_ arguments: [String:Any]) throws -> [String:Any] {
            let payload = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"get_item","arguments":arguments]])
            let (_,body) = service.handle(headers:["authorization":"Bearer synthetic","mcp-protocol-version":"2025-11-25"],payload:payload)
            let rpc = try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any]), result = try XCTUnwrap(rpc["result"] as? [String:Any]), content = try XCTUnwrap(result["content"] as? [[String:Any]])
            return try XCTUnwrap(JSONSerialization.jsonObject(with:Data((content[0]["text"] as! String).utf8)) as? [String:Any])
        }
        let text = try get(["itemID":item.id.uuidString,"offset":1,"length":3]); XCTAssertEqual(Data(base64Encoded:text["data"] as! String),Data("xam".utf8)); XCTAssertEqual(text["complete"] as? Bool,false)
        let file = try get(["itemID":item.id.uuidString,"representation":"com.copy.file-list"])
        let decoded = try JSONDecoder().decode([FileReference].self,from:XCTUnwrap(Data(base64Encoded:file["data"] as! String)))
        XCTAssertNil(decoded[0].bookmark)
    }
}
