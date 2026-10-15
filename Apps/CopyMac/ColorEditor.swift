import SwiftUI
import AppKit
import CopyCore

struct ColorEditorSheet: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @Environment(\.dismiss) private var dismiss
    @State private var color = Color.blue
    @State private var title = ""
    @State private var hex = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("编辑颜色").font(.title2)
            TextField("标题",text:$title)
            ColorPicker("选择颜色",selection:$color,supportsOpacity:false)
                .onChange(of:color) { _,value in if let rgb = NSColor(value).usingColorSpace(.sRGB) { hex = String(format:"#%02X%02X%02X",Int((rgb.redComponent*255).rounded()),Int((rgb.greenComponent*255).rounded()),Int((rgb.blueComponent*255).rounded())) } }
            TextField("六位 HEX（例如 #3578E5）",text:$hex).onChange(of:hex) { _,value in
                if value.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil, let rgb = UInt32(value.dropFirst(),radix:16) { color = Color(red:Double((rgb>>16)&255)/255,green:Double((rgb>>8)&255)/255,blue:Double(rgb&255)/255) }
            }
            RoundedRectangle(cornerRadius:12).fill(color).frame(height:120)
            if let message { Text(message).foregroundStyle(.red) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("另存新条目") { save(copy:true) }; Button("保存修订") { save(copy:false) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:480).onAppear {
            title = item.title; hex = item.text
            if let value = UInt32(item.text.trimmingCharacters(in:CharacterSet(charactersIn:"#")),radix:16) { color = Color(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255) }
        }
    }
    private func save(copy: Bool) {
        let value = hex.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
        guard value.range(of:"^#[0-9A-F]{6}$",options:.regularExpression) != nil else { message = "请输入 # 开头的六位 HEX 颜色"; return }
        if copy { model.makeText(value,title:title) } else { model.edit(item,title:title,text:value) }
        if let error = model.error { message = error + " 可另存新条目保留编辑。" } else { dismiss() }
    }
}
