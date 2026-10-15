import SwiftUI
import AppKit
import CopyCore
import ServiceManagement

extension ClipKind {
    var label: String { switch self { case .text: "文本"; case .richText: "富文本"; case .url: "链接"; case .image: "图片"; case .files: "文件"; case .color: "颜色"; case .other: "其他" } }
    var symbol: String { switch self { case .text: "text.alignleft"; case .richText: "doc.richtext"; case .url: "link"; case .image: "photo"; case .files: "doc"; case .color: "paintpalette"; case .other: "square.on.square" } }
}
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var newCollection = false
    @State private var collectionName = ""
    @State private var renameCollection = false
    @State private var editing: ClipItem?
    @State private var previewing: ClipItem?
    @State private var managingQueue = false
    @State private var creating = false
    var body: some View {
        VStack(spacing: 0) {
            if model.isUITest { Text("界面测试模式 · 仅合成资料 · 未连接系统剪贴板").font(.caption).padding(8).frame(maxWidth:.infinity).background(Color.orange.opacity(0.15)) }
            if !model.settings.captureEnabled { onboarding }
            if model.settings.conceal {
                ContentUnavailableView("演示保护已开启", systemImage: "eye.slash", description: Text("标题、内容、搜索和预览已隐藏。此功能不保证系统级防录屏。"))
                Button("关闭演示保护") { model.settings.conceal = false; model.saveSettings() }.padding()
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 160, idealWidth: 185, maxWidth: 240)
                    VStack(spacing: 0) { searchBar
                        HStack { Picker("时间",selection:$model.dateFilter) { Text("所有时间").tag(0); Text("24 小时内").tag(1); Text("7 天内").tag(7); Text("30 天内").tag(30) }.frame(width:150); TextField("来源 Bundle ID",text:$model.sourceFilter) }.padding(.horizontal).padding(.bottom,8)
                        itemList }.frame(minWidth: 300)
                    inspector.frame(minWidth: 270, idealWidth: 340)
                }
            }
            Divider(); footer
        }
        .toolbar {
            Button { model.showPanel() } label: { Label("快捷面板",systemImage:"rectangle.and.text.magnifyingglass") }
            Button { creating = true } label: { Label("新建文本", systemImage: "square.and.pencil") }
            Button { model.copySelected() } label: { Label("复制", systemImage: "doc.on.doc") }.disabled(model.selection.isEmpty || model.settings.conceal)
            Menu {
                Button("无收藏集合") { model.moveSelection(to: nil) }
                ForEach(model.collections) { c in Button(c.name) { model.moveSelection(to: c.id) } }
            } label: { Label("移到集合", systemImage: "folder.badge.plus") }.accessibilityLabel("移到集合").disabled(model.selection.isEmpty || model.settings.conceal)
            Button { model.deleteSelected() } label: { Label("删除内容", systemImage: "trash") }.disabled(model.selection.isEmpty || model.settings.conceal)
            Button("移出历史…") { model.removeHistorySelection() }.disabled(model.selection.isEmpty || model.settings.conceal)
            MCPApprovalBadge(service:model.mcp,model:model)
            SettingsLink { Label("设置", systemImage: "gearshape") }
        }
        .sheet(item: $editing) { item in
            if item.kind == .richText { RichEditorSheet(model:model,item:item) } else if item.kind == .color { ColorEditorSheet(model:model,item:item) } else { EditorView(model:model,item:item) }
        }
        .sheet(item:$previewing) { ExpandedPreview(model:model,item:$0) }
        .sheet(isPresented:$managingQueue) { QueueEditorSheet(model:model) }
        .sheet(isPresented: $creating) { EditorView(model: model, item: nil) }
        .alert("新建收藏集合", isPresented: $newCollection) { TextField("名称", text: $collectionName); Button("创建") { model.createCollection(collectionName); collectionName = "" }; Button("取消", role: .cancel) {} }
        .alert("重命名集合",isPresented:$renameCollection) { TextField("名称",text:$collectionName); Button("保存") { if var c = model.collections.first(where: { $0.id == model.collectionID }) { c.name = collectionName; do { try model.store.saveCollection(c); model.reload() } catch { model.error = error.localizedDescription } } }; Button("取消",role:.cancel) {} }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.settings.conceal ? "演示保护期间隐藏错误详情。" : model.error ?? "") }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让复制过的内容随时可找").font(.title2.bold())
            Text("开启后，Copy 会在此 Mac 上保存剪贴板变化。默认保留 30 天；机密/临时标记会跳过，但无法识别所有密码。iCloud、AI 和外部客户端访问默认关闭。")
            HStack { Button("同意并开启采集") { model.settings.captureEnabled = true; model.saveSettings() }.buttonStyle(.borderedProminent); Text("可在设置中暂停、排除应用或关闭采集。").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COPY").font(.title3.weight(.black)).tracking(3).padding(.bottom,12)
            Button { model.allItems = false; model.collectionID = nil } label: { Label("历史记录", systemImage: "clock") }
            Button { model.allItems = true; model.collectionID = nil } label: { Label("全部内容", systemImage: "square.stack") }
            HStack { Text("收藏集合").font(.caption).foregroundStyle(.secondary); Spacer(); Button { newCollection = true } label: { Image(systemName: "plus") }.buttonStyle(.plain) }.padding(.top,16)
            ForEach(model.collections) { c in
                Button { model.collectionID = c.id } label: { Label(c.name, systemImage: model.collectionID == c.id ? "folder.fill" : "folder") }
                    .foregroundStyle(collectionColor(c.color))
                    .contextMenu {
                        Button("上移集合") { model.moveCollection(c,delta:-1) }
                        Button("下移集合") { model.moveCollection(c,delta:1) }
                        Menu("集合颜色") { ForEach(["blue","green","orange","purple","red"],id:\.self) { color in
                            Button(color) { var updated = c; updated.color = color; do { try model.store.saveCollection(updated); model.reload() } catch { model.error = error.localizedDescription } }
                        } }
                    }
            }
            if model.collectionID != nil { Button("重命名当前集合…") { collectionName = model.collections.first(where: { $0.id == model.collectionID })?.name ?? ""; renameCollection = true }; Button("删除当前集合…", role: .destructive) { if let id = model.collectionID { model.removeCollectionWithReview(id) } }.font(.caption) }
            Spacer()
            queueView
            Button("导入…") { model.importArchive() }; Button("导出资料库…") { model.exportArchive() }
            Button("恢复为新资料库…") { model.restoreArchive() }
        }.buttonStyle(.plain).padding(18).frame(maxHeight: .infinity, alignment: .top).background(.quaternary.opacity(0.35))
    }
    private var queueView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("顺序队列").font(.headline)
            Text("\(model.queue.cursor) / \(model.queue.ids.count) · \(model.queue.state.rawValue)").font(.caption).monospacedDigit()
            if model.queue.state == .unknown {
                Text("上次发送结果不确定，请查看目标后确认。").font(.caption).foregroundStyle(.orange)
                Button("确认已粘贴，跳过此项") { model.queue.resolveUnknown(wasDelivered:true); model.persistQueue() }
                Button("确认未粘贴，保留此项") { model.queue.resolveUnknown(wasDelivered:false); model.persistQueue() }
            }
            HStack { Button("加入选中") { model.addSelectionToQueue() }.disabled(model.selection.isEmpty); Button(model.queue.state == .ready ? "暂停" : "启用 ⌘V") { if model.queue.state == .ready { model.pauseQueue() } else { model.armQueue() } } }
            HStack { Button("退回一项") { model.editQueue { $0.back() } }; Button("清空") { model.editQueue { $0 = QueueSession() } } }.font(.caption)
            Button("管理队列…") { managingQueue = true }
            Text("启用后在目标应用按 ⌘V 逐项粘贴。退回只调整队列，不撤销外部输入。").font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical,10)
    }
    private var searchBar: some View {
        VStack {
            if model.focusedItemID != nil { HStack { Text("链接定位 · 仅显示此项").font(.caption); Button("返回全部内容") { model.focusedItemID = nil; model.reload() } } }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索文本、标题、文件名或图片文字", text: $model.query).textFieldStyle(.plain); Picker("类型", selection: $model.kind) { Text("全部").tag(ClipKind?.none); ForEach(ClipKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.labelsHidden().frame(width: 95) }
        }.padding(14)
    }
    private func collectionColor(_ name: String) -> Color { switch name { case "green":.green; case "orange":.orange; case "purple":.purple; case "red":.red; default:.blue } }
    private var itemList: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ItemRow(item: item, conceal: false, query: model.query).tag(item.id)
                    .contextMenu {
                        Button("复制") { model.copy([item]) }
                        Button("复制为纯文本") { model.copy([item], plain: true) }
                        Button("放大预览…") { previewing = item }
                        Button("编辑 / 重命名…") { editing = item }
                        if item.kind == .image { Button("识别图片文字") { model.recognize(item) } }
                        Button("加入队列") { model.appendToQueue([item.id]) }
                        if item.collectionID != nil, model.collectionID == item.collectionID {
                            Button("移到集合顶部") { model.reposition(item,.first) }; Button("上移一项") { model.reposition(item,.previous) }; Button("下移一项") { model.reposition(item,.next) }; Button("移到集合底部") { model.reposition(item,.last) }
                        }
                    }
                    .onDrag { dragProvider(item) }
            }
            if model.hasMore { Button("加载更多") { model.reload(append: true) }.buttonStyle(.plain) }
        }.overlay { if model.items.isEmpty && !model.loading { ContentUnavailableView("暂无内容", systemImage: "tray", description: Text(model.query.isEmpty ? "开启采集后，复制的内容会出现在这里。" : "尝试其他关键词或类型。")) } }
    }
    private func dragProvider(_ item: ClipItem) -> NSItemProvider {
        if item.kind == .files { model.error = "文件及多项内容请使用右侧“拖出选中内容”，以保留全部文件。"; return NSItemProvider() }
        if let rep = item.representations.first(where: { ["public.png","public.jpeg","public.tiff"].contains($0.type) }), let data = try? model.store.data(for: rep) { let provider = NSItemProvider(); provider.registerDataRepresentation(forTypeIdentifier: rep.type, visibility: .all) { completion in completion(data,nil); return nil }; return provider }
        return NSItemProvider(object: item.text as NSString)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let item = model.firstSelected {
                HStack { Label(item.kind.label, systemImage: item.kind.symbol).foregroundStyle(.secondary); Spacer(); Button("预览") { previewing = item }; Button("编辑") { editing = item } }
                Text(item.displayTitle.isEmpty ? item.kind.label : item.displayTitle).font(.title3.bold()).lineLimit(3)
                PreviewView(model: model, item: item)
                Divider()
                Text("来源：\(item.source ?? "未知")").font(.caption)
                Text("复制于 \(item.captured.formatted()) · 共 \(item.captureCount) 次").font(.caption).foregroundStyle(.secondary)
                Text("\(item.representations.count) 种表示 · \(ByteCountFormatter.string(fromByteCount: Int64(item.representations.reduce(0) { $0 + $1.bytes }), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                if !item.ocr.isEmpty { Text("图片文字").font(.headline); ScrollView { Text(item.ocr).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }; Button("提取为文本") { model.makeText(item.ocr) } }
                Spacer(minLength: 0)
                HStack { Button("复制内容") { model.copySelected() }.buttonStyle(.borderedProminent); Button("分享…") { model.share(item) } }
                BatchDragHandle(model:model).frame(height:38)
                if item.kind == .image { Button("图片作为文件复制") { model.copy(model.selectedItems,asFiles:true) }; BatchDragHandle(model:model,asFiles:true).frame(height:38); Button("旋转 90° 并另存 PNG") { model.rotateImage(item) } }
            } else { ContentUnavailableView("选择内容", systemImage: "sidebar.right", description: Text("查看原文、附件信息及操作。")) }
        }.padding(20).frame(maxHeight: .infinity, alignment: .top)
    }
    private var footer: some View {
        HStack {
            Text(model.settings.conceal ? "内容已隐藏" : model.settings.pausedManually ? "采集已暂停" : model.status).lineLimit(1)
            if !model.undoIDs.isEmpty { Button("撤销删除") { model.undoDelete() } }
            Spacer(); Text(ByteCountFormatter.string(fromByteCount: model.usedBytes, countStyle: .file)).foregroundStyle(.secondary)
        }.font(.caption).padding(10)
    }
}
struct ItemRow: View {
    let item: ClipItem
    let conceal: Bool
    var query: String = ""
    private var highlightedTitle: AttributedString {
        let title = conceal ? "内容已隐藏" : (item.displayTitle.isEmpty ? item.kind.label : item.displayTitle)
        var attributed = AttributedString(title)
        if !conceal, !query.isEmpty, let range = attributed.range(of:query,options:[.caseInsensitive]) { attributed[range].font = .body.bold(); attributed[range].underlineStyle = .single }
        return attributed
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol).font(.title3).foregroundStyle(.tint).frame(width: 25)
            VStack(alignment: .leading, spacing: 5) { Text(highlightedTitle).lineLimit(2); HStack { Text(item.kind.label); if item.collectionID != nil { Image(systemName: "pin.fill") }; Spacer(); Text(item.captured, style: .relative) }.font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical,7).accessibilityElement(children: .ignore).accessibilityLabel("\(item.kind.label)，\(conceal ? "内容已隐藏" : String(item.displayTitle.prefix(40)))")
    }
}
struct QuickPanel: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocus: Bool
    @StateObject private var suggestions = LocalSuggestions()
    var body: some View {
        VStack(spacing: 0) {
            if model.settings.conceal { ContentUnavailableView("演示保护", systemImage: "eye.slash") }
            else {
                HStack { Image(systemName: "magnifyingglass"); TextField("查找并粘贴…", text: $model.query).textFieldStyle(.plain).font(.title3).focused($searchFocus); Text("ESC").font(.caption).foregroundStyle(.secondary) }.padding(22)
                Divider()
                if model.settings.suggestionsEnabled {
                    HStack { Button("本机推荐") { suggestions.rank(query: model.query, candidates: model.items) }; Text(suggestions.status).font(.caption).foregroundStyle(.secondary) }.padding(.horizontal)
                    ForEach(suggestions.ids, id: \.self) { id in if let item = model.items.first(where: { $0.id == id }) { Button { model.copy([item], paste: true) } label: { Label(String(item.displayTitle.prefix(60)), systemImage: "sparkles") }.buttonStyle(.plain).padding(4) } }
                }
                List(selection: $model.selection) { ForEach(Array(model.items.enumerated()), id: \.element.id) { index,item in HStack { ItemRow(item: item, conceal: false, query: model.query); if index < 9 { Text("⌘\(index+1)").font(.caption).foregroundStyle(.tertiary) } }.tag(item.id) } }
                Divider()
                HStack { Text("↵ 粘贴   ⇧↵ 纯文本   ⌘1–9 快速选择").font(.caption).foregroundStyle(.secondary); Spacer(); Button("复制") { model.copySelected() }.disabled(model.selection.isEmpty); Button("资料库") { model.hidePanel(); model.showLibrary() } }.padding(12)
            }
        }.onAppear { searchFocus = true }.onChange(of:model.panelGeneration) { _,_ in searchFocus = true }.onDisappear { suggestions.cancel() }.onChange(of: model.query) { _,_ in suggestions.cancel() }.onChange(of: model.settings.conceal) { _,_ in suggestions.cancel() }.alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.settings.conceal ? "演示保护期间隐藏错误详情。" : model.error ?? "") }
    }
}
struct PreviewView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem
    @State private var showLink = false
    var body: some View {
        Group {
            if item.kind == .image, let image = previewImage { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("图片预览") }
            else if item.kind == .richText {
                if let value = try? SafeRichText.content(item,store:model.store) { RichTextSurface(value:.constant(value)).frame(height:240).id(item.revision) }
                else { Text(item.text).textSelection(.enabled) }
            }
            else if item.kind == .files { FileReferencesView(model:model,item:item) }
            else if item.kind == .color { RoundedRectangle(cornerRadius: 12).fill(color).frame(height: 100).overlay { Text(item.text).font(.monospaced(.title3)()).foregroundStyle(.white).shadow(radius: 2) } }
            else { ScrollView { Text(item.text.isEmpty ? "该类型暂无文本预览，可按原始表示复制。" : item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 300) }
            if item.kind == .url, let url = URL(string: item.text), ["http","https"].contains(url.scheme?.lowercased() ?? "") { HStack { Button("隔离预览链接…") { showLink = true }; Link("在浏览器打开",destination:url) }.font(.caption).sheet(isPresented:$showLink) { IsolatedLinkPreview(url:url) } }
        }
    }
    private var previewImage: NSImage? { guard let rep = item.representations.first(where: { ["public.png","public.tiff","public.jpeg","com.compuserve.gif","public.heic"].contains($0.type) }), let data = try? model.store.data(for: rep) else { return nil }; return ContentPreview.image(data,maxPixels:800) }
    private var color: Color { let hex = item.text.trimmingCharacters(in: CharacterSet(charactersIn: "# \n")); let value = UInt32(hex, radix: 16) ?? 0; return Color(red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255) }
}
struct EditorView: View {
    @ObservedObject var model: AppModel
    let item: ClipItem?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item == nil ? "新建文本" : "编辑内容").font(.title2.bold())
            TextField("标题（可选）", text: $title)
            if item == nil { ContinuityImportView { model.capture($0); dismiss() }.frame(height: 44) }
            if item == nil || [.text,.richText,.url,.color].contains(item!.kind) {
                NativeTextEditor(text: $text).frame(minHeight: 260)
                if item?.kind == .richText { Text("修改正文后保存为纯文本，原富文本格式会移除。").font(.caption).foregroundStyle(.secondary) }
            }
            HStack { if let item, [.text,.url,.color].contains(item.kind) { Button("另存新条目") { model.makeText(text,title:title); if model.error == nil { dismiss() } } }; Spacer(); Button("取消", role: .cancel) { dismiss() }; Button("保存") { if let item { model.edit(item, title: title, text: text) } else { model.makeText(text, title: title) }; if model.error == nil { dismiss() } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520).onAppear { title = item?.title ?? ""; text = item?.text ?? "" }
    }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var excluded = ""
    @State private var usage = ""
    @State private var showMCP = false
    var body: some View {
        Form {
            if let error = model.error { Text(model.settings.conceal ? "演示保护期间隐藏错误详情。" : error).foregroundStyle(.red) }
            Section("此设备 · 采集和隐私") {
                Toggle("允许保存剪贴板变化", isOn: $model.settings.captureEnabled)
                Toggle("暂停，直到手动恢复", isOn: $model.settings.pausedManually)
                HStack { Text("临时暂停"); ForEach([5,30,60], id: \.self) { minutes in Button("\(minutes) 分钟") { model.settings.pausedUntil = Date().addingTimeInterval(Double(minutes)*60); model.saveSettings() } }; Button("恢复") { model.settings.pausedUntil = nil; model.settings.pausedManually = false; model.saveSettings() } }
                Toggle("演示保护（遮挡内容）", isOn: $model.settings.conceal)
                TextField("排除应用 Bundle ID，每行一个", text: $excluded, axis: .vertical).lineLimit(3...6)
                Button("保存排除规则") { model.settings.excludedApps = Set(excluded.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }); model.saveSettings() }
                Text("排除规则只影响未来采集。来源无法可靠确认时显示未知。").font(.caption).foregroundStyle(.secondary)
            }
            Section("资料库 · 保留与容量") {
                Picker("历史保留", selection: Binding(get:{ model.settings.retentionDays },set:{ model.changeRetention($0) })) { Text("1 天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30); Text("365 天").tag(365); Text("永久").tag(0) }
                Picker("此设备存储预算", selection: $model.settings.budgetBytes) { Text("256 MiB").tag(Int64(256*1024*1024)); Text("512 MiB").tag(Int64(512*1024*1024)); Text("1 GiB").tag(Int64(1024*1024*1024)) }
                Toggle("总是以纯文本复制文字内容",isOn:Binding(get:{ model.settings.alwaysPlainText ?? false },set:{ model.settings.alwaysPlainText = $0 }))
                Toggle("批量操作按点击选择的顺序",isOn:$model.useSelectionOrder)
                TextField("批量文本分隔符", text: $model.settings.separator)
                HStack { Button("重建搜索索引") { do { try model.store.rebuildIndex(); model.reload() } catch { model.error = error.localizedDescription } }; Button("清空历史…", role: .destructive) { model.clearLibrary(historyOnly:true) }; Button("清空个人资料库…",role:.destructive) { model.clearLibrary(historyOnly:false) } }
                Button("查看容量明细") {
                    do { let u = try model.store.storageUsage(); let size: (Int64)->String = { ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) }
                        usage = "数据库与索引 \(size(u.database)) · 正文/附件 \(size(u.assets)) · 文件临时副本 \(size(u.leases)) · 其他 \(size(u.other))"
                    } catch { model.error = error.localizedDescription }
                }
                if !usage.isEmpty { Text(usage).font(.caption).textSelection(.enabled) }
            }
            Section("快捷键 · 此设备") { HotkeyPreferencesView(model:model) }
            Section("系统集成") {
                SpotlightStatusView(bridge:model.spotlight)
                ForEach(model.collections) { c in
                    Toggle("Spotlight 索引：" + c.name,isOn:Binding(get:{ model.spotlightCollections.contains(c.id) },set:{ enabled in
                        if enabled { model.spotlightCollections.insert(c.id) } else { model.spotlightCollections.remove(c.id) }
                        do { try model.store.setMetadata(model.spotlightCollections,key:"spotlight.collections"); model.spotlight.synchronize(collectionIDs:model.spotlightCollections,concealed:model.settings.conceal) } catch { model.error = error.localizedDescription }
                    }))
                }
                Button("AI 客户端与 MCP 授权…") { showMCP = true }
                Toggle("允许本机模型按查询推荐（仅此设备）", isOn: $model.settings.suggestionsEnabled)
                Button("确认当前系统时间并恢复自动清理") { do { try model.store.setMetadata(Date(),key:"lastMaintenance"); model.maintain() } catch { model.error = error.localizedDescription } }
                Button("导出诊断（先预览）") { model.exportDiagnostics() }
                Button("打开辅助功能设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                HStack { Button("启用登录启动") { model.setLogin(true) }; Button("关闭登录启动") { model.setLogin(false) } }
                Text("快捷面板 \(model.panelHotkey.display) · 顺序采集 \(model.collectHotkey.display)。辅助功能仅用于发送粘贴键，不是采集前提。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 640, height: 670).sheet(isPresented: $showMCP) { MCPSettingsView(service: model.mcp, model: model) }
        .onAppear { excluded = model.settings.excludedApps.sorted().joined(separator: "\n") }
        .onChange(of: model.settings.suggestionsEnabled) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.captureEnabled) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.pausedManually) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.conceal) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.budgetBytes) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.separator) { _,_ in model.saveSettings() }
        .onChange(of: model.settings.alwaysPlainText) { _,_ in model.saveSettings() }
    }
}

struct MCPSettingsView: View {
    @ObservedObject var service: MCPService
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var history = false
    @State private var writes = false
    @State private var allowed: Set<UUID> = []
    @State private var token: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.settings.conceal { ContentUnavailableView("演示保护",systemImage:"eye.slash"); Button("完成") { token = nil; dismiss() } } else {
            HStack { Text("本机 MCP 与客户端授权").font(.title2.bold()); Spacer(); Button("完成") { token = nil; dismiss() } }
            HStack { Text(service.status).font(.caption).textSelection(.enabled); Spacer(); Button(service.running ? "关闭服务" : "开启本机服务") { if service.running { service.stop() } else { service.start() } } }
            Text("仅监听 127.0.0.1；协议版本 2025-11-25。客户端可能将读取的内容发送到其模型供应商。Copy 不开放外部应用粘贴、脚本执行或全库清空接口。").font(.caption).foregroundStyle(.secondary)
            List {
                Section("已授权客户端") {
                    ForEach(service.clients) { client in HStack { VStack(alignment: .leading) { Text(client.name); Text("\(client.collections.count) 个集合\(client.history ? " · 全部个人历史" : "") · \(client.scopes.contains("items.create") ? "可申请写入" : "只读")").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("撤销", role: .destructive) { service.revoke(client.id) } } }
                }
                Section("待审批写入 · 5 分钟有效") {
                    ForEach(service.proposals) { p in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(p.clientName) · \(p.tool)").bold()
                            Text(p.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            HStack { Button("拒绝", role: .destructive) { service.reject(p) }; Button("批准此项变更") { service.approve(p, budget: model.settings.budgetBytes); model.reload() } }
                        }.padding(.vertical,8)
                    }
                }
            }.frame(minHeight: 220)
            GroupBox("新增客户端") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("客户端名称", text: $name)
                    ScrollView { ForEach(model.collections) { c in Toggle(c.name,isOn: Binding(get: { allowed.contains(c.id) },set: { if $0 { allowed.insert(c.id) } else { allowed.remove(c.id) } })) } }.frame(maxHeight:100)
                    Toggle("额外授权：可读取全部个人历史", isOn: $history)
                    Toggle("允许申请写入（每次仍需在 Copy 内批准）", isOn: $writes)
                    Button("创建授权并显示一次令牌") { do { token = try service.createClient(name:name,collections:allowed,history:history,writes:writes); error = nil } catch { self.error = error.localizedDescription } }
                    if let token { Text("在客户端配置 Authorization: Bearer <令牌>。令牌仅在此显示，关闭后隐藏。").font(.caption); Text(token).font(.system(.caption,design:.monospaced)).textSelection(.enabled).privacySensitive() }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                }.padding(8)
            }
        }
        }.padding(24).frame(width:680,height:740)
    }
}

struct MCPApprovalBadge: View {
    @ObservedObject var service: MCPService
    @ObservedObject var model: AppModel
    @State private var show = false
    var body: some View {
        if !service.proposals.isEmpty {
            Button("待审批 \(service.proposals.count)") { show = true }
                .sheet(isPresented:$show) { MCPSettingsView(service:service,model:model) }
        }
    }
}
struct SpotlightStatusView: View {
    @ObservedObject var bridge: SpotlightBridge
    var body: some View { Text(bridge.status).font(.caption).foregroundStyle(.secondary) }
}
