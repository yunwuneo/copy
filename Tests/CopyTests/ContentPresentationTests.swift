import XCTest
import AppKit
import PDFKit
import CopyCore
import CopyStorage
@testable import CopyMac

final class ContentPresentationTests: XCTestCase {
    var root: URL!
    var store: LibraryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-preview-tests-\(UUID())"); store = try LibraryStore(root:root) }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at:root) }
    @MainActor func testRichBatchPreservesBoldAndPlainConversionLeavesSourceIntact() throws {
        let rich = NSAttributedString(string:"Bold",attributes:[.font:NSFont.boldSystemFont(ofSize:15)])
        let data = try rich.data(from:NSRange(location:0,length:rich.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        let first = try store.capture(CaptureInput(representations:["public.rtf":data,"public.utf8-plain-text":Data("Bold".utf8)],text:"Bold"))
        let second = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data("Next".utf8)],text:"Next"))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects(try ClipboardDriver.writers([first,second],store:store,plain:false,separator:" / ")))
        let combined = try SafeRichText.rtf(XCTUnwrap(board.data(forType:.rtf)))
        XCTAssertEqual(combined.string,"Bold / Next")
        XCTAssertTrue(NSFontManager.shared.traits(of:try XCTUnwrap(combined.attribute(.font,at:0,effectiveRange:nil) as? NSFont)).contains(.boldFontMask))
        board.clearContents()
        XCTAssertTrue(board.writeObjects(try ClipboardDriver.writers([first],store:store,plain:true,separator:"\n")))
        XCTAssertEqual(board.string(forType:.string),"Bold"); XCTAssertNil(board.data(forType:.rtf))
        XCTAssertEqual(try store.data(for:XCTUnwrap(first.representations.first { $0.type == "public.rtf" })),data)
    }
    @MainActor func testHTMLPreviewHasNoActiveResourcesAndBatchRequiresExplicitLoss() throws {
        let html = "<b>Safe &amp; &#20013;</b><script>secret()</script><img src='https://example.invalid/track'><a href='file:///private/value'>link</a>"
        let value = SafeRichText.html(html)
        XCTAssertEqual(value.string,"Safe & 中link"); XCTAssertNil(value.attribute(.link,at:value.length-1,effectiveRange:nil))
        XCTAssertTrue(NSFontManager.shared.traits(of:try XCTUnwrap(value.attribute(.font,at:0,effectiveRange:nil) as? NSFont)).contains(.boldFontMask))
        XCTAssertThrowsError(try SafeRichText.rtf(Data("{\\rtf1 {\\object external}}".utf8)))
        let item = try store.capture(CaptureInput(representations:["public.html":Data(html.utf8)],text:"Safe & 中link"))
        XCTAssertThrowsError(try ClipboardDriver.writers([item,item],store:store,plain:false,separator:"\n"))
    }
    @MainActor func testGIFFileOutputPreservesBytesAndRejectsMixedText() throws {
        let data = try XCTUnwrap(Data(base64Encoded:"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let item = try store.capture(CaptureInput(representations:["com.compuserve.gif":data],text:"",kind:.image))
        let outputs = try ClipboardDriver.writers([item],store:store,plain:false,separator:"\n",asFiles:true)
        let file = try XCTUnwrap(outputs.first as? NSURL) as URL
        XCTAssertEqual(file.pathExtension,"gif"); XCTAssertEqual(try Data(contentsOf:file),data)
        let text = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data("text".utf8)],text:"text"))
        XCTAssertThrowsError(try ClipboardDriver.writers([item,text],store:store,plain:false,separator:"\n",asFiles:true))
    }
    @MainActor func testPDFPagesAndImageThumbnailBound() throws {
        let image = NSImage(size:NSSize(width:640,height:200))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x:0,y:0,width:640,height:200).fill(); image.unlockFocus()
        let thumbnail = try XCTUnwrap(ContentPreview.image(XCTUnwrap(image.tiffRepresentation),maxPixels:80))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width,thumbnail.size.height),80)
        let document = PDFDocument(); document.insert(try XCTUnwrap(PDFPage(image:image)),at:0); document.insert(try XCTUnwrap(PDFPage(image:image)),at:1)
        let item = try store.capture(CaptureInput(representations:["com.adobe.pdf":XCTUnwrap(document.dataRepresentation())],text:"synthetic PDF",kind:.other))
        XCTAssertEqual(try ContentPreview.pdf(item,store:store)?.pageCount,2)
    }
    func testRevisionConflictPreservesBothContentAndTitleAndCanSaveCopy() throws {
        let input = CaptureInput(representations:["public.utf8-plain-text":Data("original".utf8)],text:"original")
        let item = try store.createContent(input,title:"Old",budget:512*1024*1024)
        let current = try store.update(item.id,expectedRevision:item.revision) { $0.title = "Newer" }
        let replacement = CaptureInput(representations:["public.utf8-plain-text":Data("draft".utf8)],text:"draft")
        XCTAssertThrowsError(try store.replaceContent(item.id,expectedRevision:item.revision,input:replacement,budget:512*1024*1024,title:"Stale"))
        XCTAssertEqual(try store.item(item.id)?.text,current.text); XCTAssertEqual(try store.item(item.id)?.title,"Newer")
        let saved = try store.createContent(replacement,title:"Copy",budget:512*1024*1024)
        XCTAssertNotEqual(saved.id,item.id); XCTAssertEqual(saved.text,"draft"); XCTAssertEqual(saved.title,"Copy")
    }
    func testQueueEditsKeepSentPrefixAndBlockUncertainResults() throws {
        let ids = (0..<4).map { _ in UUID() }; var q = QueueSession(); try q.append(ids); q.arm(); _ = try q.begin(); q.sent()
        try q.reverseRemaining(); XCTAssertEqual(q.ids,[ids[0],ids[3],ids[2],ids[1]]); XCTAssertEqual(q.cursor,1); XCTAssertEqual(q.state,.paused)
        try q.movePending(from:3,to:1); try q.removePending(at:2); XCTAssertEqual(q.ids,[ids[0],ids[1],ids[2]])
        XCTAssertThrowsError(try q.removePending(at:0))
        q.uncertain(); XCTAssertThrowsError(try q.reverseRemaining()); XCTAssertThrowsError(try q.append([UUID()])); q.back(); XCTAssertEqual(q.state,.unknown); XCTAssertEqual(q.cursor,1)
        q.resolveUnknown(wasDelivered:false); try q.removePending(at:1); XCTAssertEqual(q.ids,[ids[0],ids[2]])
    }
    @MainActor func testIsolatedLinkConfigurationDisablesPersistenceAndScript() {
        let config = IsolatedWebPolicy.configuration()
        XCTAssertFalse(config.websiteDataStore.isPersistent); XCTAssertFalse(config.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(config.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(IsolatedWebPolicy.allows(URL(string:"https://example.com")))
        for url in ["file:///private/value","javascript:alert(1)","copy://item/123","data:text/html,secret"] { XCTAssertFalse(IsolatedWebPolicy.allows(URL(string:url))) }
    }
    func testOldSettingsDecodeWithoutPlainTextPreference() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(LibrarySettings())) as? [String:Any]); json.removeValue(forKey:"alwaysPlainText")
        let settings = try JSONDecoder().decode(LibrarySettings.self,from:JSONSerialization.data(withJSONObject:json)); XCTAssertNil(settings.alwaysPlainText)
    }
}
