import AppKit
import SwiftUI
import CopyCore
import CopyStorage
import PDFKit
import ImageIO

/// HTML is tokenized into text and a small formatting allowlist. It is never loaded by
/// WebKit or NSAttributedString's HTML importer, so no URL, script or file is resolved.
@MainActor enum SafeRichText {
    static func rtf(_ data: Data) throws -> NSAttributedString {
        let source = String(decoding:data,as:UTF8.self).lowercased()
        guard !["includepicture","includetext","ddeauto","\\object","\\objdata"].contains(where:source.contains) else { throw CopyError.unavailable("富文本含外部对象，仅显示纯文本；原始表示仍保留") }
        guard let value = NSAttributedString(rtf:data,documentAttributes:nil) else { throw CopyError.invalid("RTF 内容损坏") }
        let result = NSMutableAttributedString(attributedString:value)
        result.removeAttribute(.link,range:NSRange(location:0,length:result.length))
        return result
    }
    static func html(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string:"")
        let expression = try! NSRegularExpression(pattern:"<!--[\\s\\S]*?-->|<[^>]*>|[^<]+")
        var bold = 0, italic = 0, underline = 0, hidden: String?
        func append(_ text: String) {
            var traits: NSFontTraitMask = []
            if bold > 0 { traits.insert(.boldFontMask) }; if italic > 0 { traits.insert(.italicFontMask) }
            let font = NSFontManager.shared.convert(.systemFont(ofSize:14),toHaveTrait:traits)
            var attrs: [NSAttributedString.Key:Any] = [.font:font]
            if underline > 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string:entities(text),attributes:attrs))
        }
        for match in expression.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
            guard let range = Range(match.range,in:source) else { continue }; let token = String(source[range])
            guard token.hasPrefix("<") else { if hidden == nil { append(token) }; continue }
            if token.hasPrefix("<!--") { continue }
            let closing = token.hasPrefix("</")
            let name = token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber }.lowercased()
            if let blocked = hidden { if closing && name == blocked { hidden = nil }; continue }
            if ["script","style","iframe","object","svg","template"].contains(name) { if !closing { hidden = name }; continue }
            let delta = closing ? -1 : 1
            switch name {
            case "b","strong": bold = max(0,bold+delta)
            case "i","em": italic = max(0,italic+delta)
            case "u": underline = max(0,underline+delta)
            case "br": append("\n")
            case "p","div","tr","li","h1","h2","h3": if result.length > 0 && !result.string.hasSuffix("\n") { append("\n") }
            case "td","th": if closing { append("\t") }
            default: break
            }
        }
        return result
    }
    static func entities(_ text: String) -> String {
        var output = text
        let pattern = try! NSRegularExpression(pattern:"&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in pattern.matches(in:output,range:NSRange(output.startIndex...,in:output)).reversed() {
            guard let digitsRange = Range(match.range(at:1),in:output), let range = Range(match.range,in:output) else { continue }
            let digits = String(output[digitsRange]); let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(),radix:16) : UInt32(digits)
            if let value, let scalar = UnicodeScalar(value) { output.replaceSubrange(range,with:String(scalar)) }
        }
        for (entity,value) in [("&lt;","<"),("&gt;",">"),("&quot;","\""),("&apos;","'"),("&nbsp;"," "),("&amp;","&")] { output = output.replacingOccurrences(of:entity,with:value) }
        return output
    }
    static func content(_ item: ClipItem, store: LibraryStore) throws -> NSAttributedString {
        if let rep = item.representations.first(where:{ $0.type == "public.rtf" }) { return try rtf(store.data(for:rep)) }
        if let rep = item.representations.first(where:{ $0.type == "public.html" }) { return html(String(decoding:try store.data(for:rep),as:UTF8.self)) }
        return NSAttributedString(string:item.text)
    }
}

struct RichTextSurface: NSViewRepresentable {
    @Binding var value: NSAttributedString
    var editable = false
    @MainActor static func toggleFont(_ trait: NSFontTraitMask) {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.delegate is Coordinator, view.isEditable else { return }
        let range = view.selectedRange(), font = (range.length > 0 ? view.textStorage?.attribute(.font,at:range.location,effectiveRange:nil) as? NSFont : view.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize:14)
        let remove = NSFontManager.shared.traits(of:font).contains(trait)
        if range.length == 0 { view.typingAttributes[.font] = remove ? NSFontManager.shared.convert(font,toNotHaveTrait:trait) : NSFontManager.shared.convert(font,toHaveTrait:trait); return }
        guard view.shouldChangeText(in:range,replacementString:nil), let storage = view.textStorage else { return }
        let styled = NSMutableAttributedString(attributedString:storage.attributedSubstring(from:range))
        styled.enumerateAttribute(.font,in:NSRange(location:0,length:styled.length)) { value, part, _ in
            let original = value as? NSFont ?? .systemFont(ofSize:14)
            styled.addAttribute(.font,value:remove ? NSFontManager.shared.convert(original,toNotHaveTrait:trait) : NSFontManager.shared.convert(original,toHaveTrait:trait),range:part)
        }
        storage.replaceCharacters(in:range,with:styled); view.didChangeText()
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(), view = scroll.documentView as! NSTextView
        view.isRichText = true; view.isEditable = editable; view.isSelectable = true; view.allowsUndo = editable
        view.importsGraphics = false; view.usesFontPanel = editable; view.textContainerInset = NSSize(width:12,height:12)
        view.delegate = context.coordinator; view.textStorage?.setAttributedString(value)
        view.setAccessibilityLabel(editable ? "富文本编辑区" : "安全富文本预览")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        if !view.attributedString().isEqual(to:value) { view.textStorage?.setAttributedString(value) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextSurface
        init(_ parent: RichTextSurface) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { parent.value = NSAttributedString(attributedString:view.attributedString()) } }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
    }
}

@MainActor enum ContentPreview {
    static func image(_ data: Data, maxPixels: Int = 1600) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maxPixels,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
    }
    static func pdf(_ item: ClipItem, store: LibraryStore) throws -> PDFDocument? {
        for rep in item.representations where rep.type == "com.adobe.pdf" || rep.type.hasPrefix("com.copy.file-snapshot.") {
            let data = try store.data(for:rep)
            if data.starts(with:Data("%PDF-".utf8)) { return PDFDocument(data:data) }
        }
        return nil
    }
}
struct ExpandedPreview: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: Double = 1
    @State private var page = 0
    @State private var pdf: PDFDocument?
    @State private var image: NSImage?
    @State private var rich = NSAttributedString(string:"")
    @State private var error: String?
    var body: some View {
        VStack(spacing:12) {
            HStack { Text("内容预览").font(.title2); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            if model.settings.conceal { ContentUnavailableView("演示保护",systemImage:"eye.slash") }
            else if let error { Text(error).foregroundStyle(.red) }
            else if let pdf {
                HStack { Button("上一页") { page = max(0,page-1) }.disabled(page == 0); Text("\(page+1) / \(pdf.pageCount)"); Button("下一页") { page = min(pdf.pageCount-1,page+1) }.disabled(page+1 >= pdf.pageCount); Slider(value:$zoom,in:0.5...2).frame(width:120).accessibilityLabel("PDF 缩放") }
                ScrollView([.horizontal,.vertical]) { if let p = pdf.page(at:page) { Image(nsImage:p.thumbnail(of:NSSize(width:1400*zoom,height:1800*zoom),for:.mediaBox)).resizable().frame(width:pageSize(p).width,height:pageSize(p).height).accessibilityLabel("PDF 第 \(page+1) 页") } }
                Text("PDF 仅渲染页面；不执行脚本或链接动作。多文件中的第一个 PDF 在此预览。").font(.caption).foregroundStyle(.secondary)
            } else if let image {
                HStack { Text("缩放"); Slider(value:$zoom,in:0.25...3).frame(width:200); Text(zoom,format:.percent.precision(.fractionLength(0))) }
                ScrollView([.horizontal,.vertical]) { Image(nsImage:image).resizable().frame(width:image.size.width*zoom,height:image.size.height*zoom) }
                Text("预览使用缩略图；动画显示第一帧，原始数据和文件输出保留动画。").font(.caption).foregroundStyle(.secondary)
            } else { RichTextSurface(value:$rich).frame(maxWidth:.infinity,maxHeight:.infinity) }
        }.padding(20).frame(width:760,height:600).onAppear {
            do {
                pdf = try ContentPreview.pdf(item,store:model.store)
                if pdf == nil, item.kind == .image, let rep = item.representations.first(where:{ ["public.png","public.tiff","public.jpeg","public.heic","com.compuserve.gif"].contains($0.type) }) { image = ContentPreview.image(try model.store.data(for:rep)) }
                rich = try SafeRichText.content(item,store:model.store)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func pageSize(_ page: PDFPage) -> NSSize {
        let size = page.bounds(for:.mediaBox).size
        let scale = min(700/max(1,size.width),440/max(1,size.height))*zoom
        return NSSize(width:size.width*scale,height:size.height*scale)
    }
}
struct RichEditorSheet: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @Environment(\.dismiss) private var dismiss
    @State private var value = NSAttributedString(string:"")
    @State private var title = ""
    @State private var loaded = false
    @State private var error: String?
    private var preserveAsCopy: Bool { !item.representations.contains(where:{ $0.type == "public.rtf" }) || item.representations.contains(where:{ !["public.rtf","public.utf8-plain-text"].contains($0.type) }) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("编辑富文本").font(.title2)
            TextField("标题",text:$title)
            HStack { Button("粗体") { RichTextSurface.toggleFont(.boldFontMask) }; Button("斜体") { RichTextSurface.toggleFont(.italicFontMask) }; Button("下划线") { NSApp.sendAction(Selector(("underline:")),to:nil,from:nil) } }
            if preserveAsCopy { Text("此条目含 HTML 或其他表示。编辑将另存为 RTF 副本，保留原件；HTML 仅呈现基本排版。").font(.caption) }
            RichTextSurface(value:$value,editable:true).frame(minHeight:300)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("另存新条目") { save(copy:true) }.disabled(!loaded); Button(preserveAsCopy ? "保存副本" : "保存修订") { save(copy:preserveAsCopy) }.disabled(!loaded).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width:620).onAppear { title = item.title; do { value = try SafeRichText.content(item,store:model.store); loaded = true } catch { self.error = error.localizedDescription } }
    }
    private func save(copy: Bool) {
        do {
            let rtf = try value.data(from:NSRange(location:0,length:value.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
            let input = CaptureInput(representations:["public.rtf":rtf,"public.utf8-plain-text":Data(value.string.utf8)],text:value.string,kind:.richText)
            if copy { _ = try model.store.createContent(input,title:title,budget:model.settings.budgetBytes) }
            else { _ = try model.store.replaceContent(item.id,expectedRevision:item.revision,input:input,budget:model.settings.budgetBytes,title:title) }
            model.reload(); dismiss()
        } catch { self.error = error.localizedDescription + " 可另存新条目以保留当前编辑。" }
    }
}
