import AppKit
import PDFKit
import CopyCore
import CopyStorage

/// Called only after the explicit isolated UI-test mode has been selected.
@MainActor enum SyntheticFixtures {
    static func seed(_ store: LibraryStore) throws {
        guard try store.metadata(Bool.self,key:"ui.fixtures.v2") != true else { return }
        let text = NSAttributedString(string:"格式验收：粗体文字\n第二行正常内容",attributes:[.font:NSFont.boldSystemFont(ofSize:17)])
        let rtf = try text.data(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        _ = try store.capture(CaptureInput(representations:["public.rtf":rtf,"public.utf8-plain-text":Data(text.string.utf8)],text:text.string,source:"synthetic"))
        let image = NSImage(size:NSSize(width:420,height:260))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x:0,y:0,width:420,height:260).fill()
        ("Synthetic PDF / 2 pages" as NSString).draw(at:NSPoint(x:30,y:120),withAttributes:[.font:NSFont.systemFont(ofSize:23),.foregroundColor:NSColor.black]); image.unlockFocus()
        let pdf = PDFDocument()
        for i in 0..<2 { if let page = PDFPage(image:image) { pdf.insert(page,at:i) } }
        if let data = pdf.dataRepresentation() { _ = try store.capture(CaptureInput(representations:["com.adobe.pdf":data],text:"PDF 预览验收：两页合成文档",source:"synthetic",kind:.other)) }
        if let gif = Data(base64Encoded:"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7") { _ = try store.capture(CaptureInput(representations:["com.compuserve.gif":gif],text:"GIF 文件验收",source:"synthetic",kind:.image)) }
        let collection = ClipCollection(name:"过期收藏验收"); try store.saveCollection(collection)
        let old = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data("过期收藏：取消后可撤销".utf8)],text:"过期收藏：取消后可撤销",source:"synthetic"),now:Date().addingTimeInterval(-40*86400))
        _ = try store.update(old.id,expectedRevision:old.revision) { $0.collectionID = collection.id }
        try store.setMetadata(true,key:"ui.fixtures.v2")
    }
}
