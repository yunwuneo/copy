import AppKit
import SwiftUI
import CopyCore
import CopyStorage
import ServiceManagement
import Carbon

@MainActor final class AppModel: ObservableObject {
    let store: LibraryStore
    let isUITest: Bool
    let clipboard = ClipboardDriver()
    let hotkeys = GlobalHotkeys()
    @Published var panelHotkey = HotkeyPreference(letter:"V",modifier:"shift")
    @Published var collectHotkey = HotkeyPreference(letter:"C",modifier:"shift")
    let mcp: MCPService
    let spotlight: SpotlightBridge
    @Published var spotlightCollections: Set<UUID> = []
    @Published var sourceFilter = "" { didSet { reload() } }
    @Published var dateFilter = 0 { didSet { reload() } }
    private let worker = DispatchQueue(label: "copy.persistence", qos: .userInitiated)
    private let ocrWorker = DispatchQueue(label: "copy.ocr", qos: .utility)
    @Published var settings: LibrarySettings
    @Published var items: [ClipItem] = []
    @Published var collections: [ClipCollection] = []
    @Published var selection: Set<UUID> = [] { didSet {
        selectionOrder.removeAll { !selection.contains($0) }
        selectionOrder += items.map(\.id).filter { selection.contains($0) && !selectionOrder.contains($0) }
    } }
    private var selectionOrder: [UUID] = []
    @Published var useSelectionOrder = false { didSet { try? store.setMetadata(useSelectionOrder,key:"selectionOrder") } }
    @Published var focusedItemID: UUID?
    @Published var query = "" { didSet { focusedItemID = nil; scheduleSearch() } }
    @Published var kind: ClipKind? { didSet { reload() } }
    @Published var collectionID: UUID? { didSet { focusedItemID = nil; selection = []; reload() } }
    @Published var allItems = false { didSet { reload() } }
    @Published var status = "准备就绪"
    @Published var error: String?
    @Published var queue: QueueSession
    @Published var collecting = false
    @Published var undoIDs: [UUID] = []
    @Published var usedBytes: Int64 = 0
    @Published var loading = false
    @Published var hasMore = false
    @Published var panelGeneration = 0
    var panelVisible = false
    var showPanel: () -> Void = {}
    var hidePanel: () -> Void = {}
    var showLibrary: () -> Void = {}
    var target: NSRunningApplication?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var maintenance: Timer?
    private var undoExpiry: Task<Void,Never>?
    var dragLeases: Set<URL> = []
    init(root: URL? = nil, uiTest: Bool = false) throws {
        isUITest = uiTest
        let location = root ?? LibraryLocation.current
        store = try LibraryStore(root: location)
        mcp = MCPService(store: store)
        spotlight = SpotlightBridge(store: store)
        spotlightCollections = try store.metadata(Set<UUID>.self,key:"spotlight.collections") ?? []
        settings = try store.metadata(LibrarySettings.self, key: "settings") ?? LibrarySettings()
        useSelectionOrder = try store.metadata(Bool.self,key:"selectionOrder") ?? false
        let configuredKeys = try store.metadata([HotkeyPreference].self,key:"hotkeys")
        if let configuredKeys, configuredKeys.count == 2 { panelHotkey = configuredKeys[0]; collectHotkey = configuredKeys[1] }
        queue = try store.metadata(QueueSession.self, key: "queue") ?? QueueSession(); queue.restore()
        undoIDs = try store.undoableDeletions().map(\.id)
        clipboard.activeLeases = try store.metadata(Set<URL>.self,key:"clipboard.leases") ?? []
        clipboard.onExternalChange = { [weak self] in try? self?.store.setMetadata(Set<URL>(),key:"clipboard.leases") }
        clipboard.settings = { [weak self] in self?.settings ?? LibrarySettings() }
        clipboard.onError = { [weak self] in self?.status = $0 }
        clipboard.onCapture = { [weak self] in self?.capture($0) }
        hotkeys.action = { [weak self] id in Task { @MainActor in
            guard let self else { return }
            switch id {
            case 1: self.showPanel()
            case 2: self.collecting.toggle(); self.status = self.collecting ? "顺序采集中，再按 \(self.collectHotkey.display) 停止" : "顺序采集已停止"
            case 3: self.pasteNext()
            default: break
            }
        } }
        do {
            try panelHotkey.validate(); try collectHotkey.validate()
            if panelHotkey.isEnabled { try hotkeys.register(id:1,key:HotkeyPreference.keys[panelHotkey.letter]!,modifiers:panelHotkey.flags) }
            if collectHotkey.isEnabled { try hotkeys.register(id:2,key:HotkeyPreference.keys[collectHotkey.letter]!,modifiers:collectHotkey.flags) }
        } catch { self.error = error.localizedDescription }
        if !uiTest { clipboard.start() }
        if uiTest, try store.counts().items == 0 {
            let c = ClipCollection(name:"测试收藏"); try store.saveCollection(c)
            for text in ["欢迎使用 Copy：这是独立的界面测试资料", "项目剪切板：中文搜索与收藏演示", "https://example.com", "#3578E5", "第一行\n第二行\n第三行"] {
                let item = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data(text.utf8)],text:text,source:"synthetic"))
                if text.hasPrefix("项目") { _ = try store.update(item.id,expectedRevision:item.revision) { $0.collectionID = c.id } }
            }
        }
        if uiTest { try SyntheticFixtures.seed(store) }
        reload()
        maintenance = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.maintain() } }
        maintain()
        scheduleUndoExpiry()
    }
    var selectedItems: [ClipItem] { let selected = items.filter { selection.contains($0.id) }; return useSelectionOrder ? selectionOrder.compactMap { id in selected.first(where:{ $0.id == id }) } : selected }
    var firstSelected: ClipItem? { selectedItems.first }
    func configureHotkeys(panel: HotkeyPreference, collect: HotkeyPreference) {
        do {
            try panel.validate(); try collect.validate(); guard !panel.isEnabled || !collect.isEnabled || panel.letter != collect.letter || panel.modifier != collect.modifier else { throw CopyError.invalid("两个动作不能使用同一个快捷键") }
            hotkeys.unregister(1); hotkeys.unregister(2)
            if panel.isEnabled { try hotkeys.register(id:1,key:HotkeyPreference.keys[panel.letter]!,modifiers:panel.flags) }
            if collect.isEnabled { try hotkeys.register(id:2,key:HotkeyPreference.keys[collect.letter]!,modifiers:collect.flags) }
            try store.setMetadata([panel,collect],key:"hotkeys")
            panelHotkey = panel; collectHotkey = collect; status = "快捷键已更新"
        } catch {
            hotkeys.unregister(1); hotkeys.unregister(2)
            if panelHotkey.isEnabled { try? hotkeys.register(id:1,key:HotkeyPreference.keys[panelHotkey.letter] ?? 9,modifiers:panelHotkey.flags) }
            if collectHotkey.isEnabled { try? hotkeys.register(id:2,key:HotkeyPreference.keys[collectHotkey.letter] ?? 8,modifiers:collectHotkey.flags) }
            self.error = error.localizedDescription
        }
    }
    func saveSettings() {
        do { try store.setMetadata(settings, key: "settings"); spotlight.synchronize(collectionIDs:spotlightCollections,concealed:settings.conceal) } catch { self.error = error.localizedDescription }
    }
    func changeRetention(_ days: Int) {
        do {
            let now = Date()
            let impact = try store.removalImpact(historyOnly:true,before:days > 0 ? now.addingTimeInterval(-Double(days)*86400) : nil)
            if days > 0, settings.retentionDays == 0 || days < settings.retentionDays, impact.records > 0 {
                let alert = NSAlert(); alert.messageText = "缩短历史保留期为 \(days) 天？"
                alert.informativeText = "当前有 \(impact.records) 项超出期限，其中 \(impact.deleted) 项未收藏，将永久删除；收藏内容保留。预计可回收正文及附件 \(ByteCountFormatter.string(fromByteCount:impact.reclaimableAssetBytes,countStyle:.file))。当前未连接云端。可撤销删除仍保留到其原定截止时间。"
                alert.addButton(withTitle:"更改并清理过期历史"); alert.addButton(withTitle:"取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            var updated = settings; updated.retentionDays = days
            try store.applyRetention(updated,expectedToken:impact.reviewToken,now:now)
            settings = updated; reload()
        } catch { self.error = error.localizedDescription }
    }
    func scheduleSearch() { searchTask?.cancel(); searchTask = Task { try? await Task.sleep(for: .milliseconds(120)); guard !Task.isCancelled else { return }; reload() } }
    func reload(append: Bool = false) {
        searchGeneration += 1; let generation = searchGeneration
        var request = SearchQuery(text: query, collectionID: collectionID, historyOnly: collectionID == nil && !allItems)
        if let kind { request.kinds = [kind] }; if !sourceFilter.isEmpty { request.sources = [sourceFilter] }; if dateFilter > 0 { request.from = Date().addingTimeInterval(-Double(dateFilter)*86400) }; request.offset = append ? items.count : 0
        let focusedID = focusedItemID
        loading = true
        worker.async { [weak self, store] in
            let result = Result { (try focusedID.map { try store.item($0).map { [$0] } ?? [] } ?? store.search(request), try store.collections(), try store.diskUsage()) }
            Task { @MainActor in
                guard let self, generation == self.searchGeneration else { return }; self.loading = false
                switch result {
                case .success(let (results, collections, bytes)):
                    self.items = append ? self.items + results : results; self.collections = collections; self.usedBytes = bytes; self.hasMore = focusedID == nil && results.count == 50
                    self.selection.formIntersection(Set(self.items.map(\.id)))
                    if let focusedID, results.contains(where:{ $0.id == focusedID }) { self.selection = [focusedID] }
                    self.spotlight.synchronize(collectionIDs:self.spotlightCollections,concealed:self.settings.conceal)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func focusItem(_ id: UUID) {
        query = ""; kind = nil; dateFilter = 0; sourceFilter = ""; collectionID = nil; allItems = true
        focusedItemID = id; reload()
    }
    func clearLibrary(historyOnly: Bool) {
        do {
            let impact = try store.removalImpact(historyOnly:historyOnly)
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = historyOnly ? "清空个人历史？" : "清空个人资料库？"
            alert.informativeText = "影响 \(impact.records) 项，彻底删除 \(impact.deleted) 项，解除 \(historyOnly ? 0 : impact.collections) 个集合。可回收正文及附件约 \(ByteCountFormatter.string(fromByteCount:impact.reclaimableAssetBytes,countStyle:.file))。\n\(historyOnly ? "收藏内容保留。" : "收藏内容也会删除，队列和待审批请求会清空。") 此操作不可撤销。当前版本未连接云端；不会删除云端或共享资料。正在使用的文件临时副本在租约到期后回收。"
            alert.addButton(withTitle:historyOnly ? "清空历史" : "清空个人资料库"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if historyOnly { try store.clearHistory(expectedToken:impact.reviewToken) }
            else { try store.clearPersonalLibrary(expectedToken:impact.reviewToken); hotkeys.unregister(3); queue = QueueSession(); mcp.stop(); mcp.proposals = [] }
            undoIDs = []; reload()
        } catch { self.error = error.localizedDescription }
    }
    func removeHistorySelection() {
        do {
            let ids = Set(selectedItems.map(\.id)), impact = try store.removalImpact(ids:ids,historyOnly:true)
            let alert = NSAlert(); alert.messageText = "移出历史？"
            alert.informativeText = "移除 \(impact.records) 项历史资格；\(impact.deleted) 项没有收藏，将彻底删除。可回收约 \(ByteCountFormatter.string(fromByteCount:impact.reclaimableAssetBytes,countStyle:.file))。收藏内容保留；不可撤销，当前未连接云端。"
            alert.addButton(withTitle:"移出历史"); alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try store.removeFromHistory(Array(ids),expectedToken:impact.reviewToken); reload()
        } catch { self.error = error.localizedDescription }
    }
    func moveCollection(_ collection: ClipCollection, delta: Int) {
        do {
            var ids = collections.map(\.id)
            guard let index = ids.firstIndex(of:collection.id), ids.indices.contains(index + delta) else { return }
            ids.swapAt(index,index + delta); try store.orderCollections(ids); reload()
        } catch { self.error = error.localizedDescription }
    }
    func capture(_ input: CaptureInput) {
        let budget = settings.budgetBytes, addToQueue = collecting
        worker.async { [weak self, store] in
            let result = Result { try store.capture(input, budget: budget) }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let item):
                    self.status = "已保存 · \(item.kind.rawValue)"
                    if addToQueue { self.appendToQueue([item.id]) }
                    if !self.panelVisible { self.reload() }
                    self.recognize(item)
                case .failure(let error): self.status = "未保存：\(error.localizedDescription)"
                }
            }
        }
    }
    func recognize(_ item: ClipItem) {
        guard item.kind == .image, item.ocr.isEmpty, let rep = item.representations.first(where: { ["public.png","public.jpeg","public.tiff","public.heic"].contains($0.type) }) else { return }
        ocrWorker.async { [weak self, store] in
            do {
                let text = try OCRService.recognize(store.data(for: rep))
                guard !text.isEmpty else { return }
                _ = try store.update(item.id, expectedRevision: item.revision) { $0.ocr = text }
                Task { @MainActor in if self?.panelVisible == false { self?.reload() } }
            } catch CopyError.conflict { /* A later revision owns the index. */ }
            catch { Task { @MainActor in self?.status = "OCR 未完成，可重新尝试" } }
        }
    }
    func makeText(_ text: String, title: String = "") {
        error = nil
        do {
            let input = CaptureInput(representations: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)], text: text)
            _ = try store.createContent(input,title:title,budget:settings.budgetBytes)
            reload()
        } catch { self.error = error.localizedDescription }
    }
    func edit(_ item: ClipItem, title: String, text: String) {
        error = nil
        do {
            if item.text == text { _ = try store.update(item.id, expectedRevision: item.revision) { $0.title = title } }
            else { _ = try store.editText(item.id, expectedRevision: item.revision, title: title, text: text, budget: settings.budgetBytes) }
            reload()
        } catch { self.error = error.localizedDescription }
    }
    func moveSelection(to collection: UUID?) {
        do {
            if collection == nil {
                let now = Date(), ids = selectedItems.map(\.id)
                let review = try store.unpinReview(ids,days:settings.retentionDays,now:now)
                if review.onlyPinned > 0 {
                    let alert = NSAlert(); alert.messageText = "取消收藏后有 \(review.onlyPinned) 项失去保留位置"
                    alert.informativeText = "这些内容已不在有效历史中。确认后进入 10 秒删除撤销期；撤销会恢复原集合。其余内容仍留在历史中。当前未连接云端。"
                    alert.addButton(withTitle:"取消收藏并删除过期项"); alert.addButton(withTitle:"取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                undoIDs = try store.unpin(ids,expectedToken:review.token,days:settings.retentionDays,now:now); scheduleUndoExpiry()
            } else { try store.moveItems(selectedItems, to: collection) }
            reload()
        }
        catch { self.error = error.localizedDescription }
    }
    func removeCollectionWithReview(_ id: UUID) {
        do {
            let now = Date(), review = try store.collectionRemovalReview(id,days:settings.retentionDays,now:now)
            let alert = NSAlert(); alert.messageText = "删除收藏集合？"
            alert.informativeText = "共 \(review.members) 项，其中 \(review.onlyPinned) 项仅靠收藏保留。内容附件共 \(ByteCountFormatter.string(fromByteCount:review.bytes,countStyle:.file))。删除不可撤销，当前未连接云端。可取消后先导出。"
            alert.addButton(withTitle:review.onlyPinned == 0 ? "保留有效历史，仅删除集合" : "转移仅收藏项，保留有效历史")
            alert.addButton(withTitle:"保留有效历史，删除仅收藏项")
            alert.addButton(withTitle:"删除集合及全部内容")
            alert.addButton(withTitle:"取消")
            let answer = alert.runModal(); let mode: CollectionRemovalMode
            switch answer {
            case .alertFirstButtonReturn:
                if review.onlyPinned == 0 { mode = .keepHistory }
                else {
                    let targets = collections.filter { $0.id != id }
                    guard !targets.isEmpty else { throw CopyError.unavailable("请先新建目标集合，再转移仅收藏内容") }
                    let picker = NSPopUpButton(frame:NSRect(x:0,y:0,width:320,height:30)); picker.addItems(withTitles:targets.enumerated().map { "\($0.offset+1). \($0.element.name)" })
                    let transfer = NSAlert(); transfer.messageText = "选择接收 \(review.onlyPinned) 项内容的集合"; transfer.accessoryView = picker
                    transfer.addButton(withTitle:"转移并删除原集合"); transfer.addButton(withTitle:"取消")
                    guard transfer.runModal() == .alertFirstButtonReturn else { return }; mode = .transferOrphans(targets[picker.indexOfSelectedItem].id)
                }
            case .alertSecondButtonReturn: mode = .deleteOrphans
            case .alertThirdButtonReturn: mode = .deleteAll
            default: return
            }
            try store.removeCollection(id,mode:mode,expectedToken:review.token,days:settings.retentionDays,now:now)
            collectionID = nil; reload()
        } catch { self.error = error.localizedDescription }
    }
    func reposition(_ item: ClipItem, _ position: ItemPosition) {
        do { try store.repositionItem(item.id,expectedRevision:item.revision,position:position); reload() }
        catch { self.error = error.localizedDescription }
    }
    func createCollection(_ name: String) {
        do { try store.saveCollection(ClipCollection(name: name, position: collections.count)); reload() }
        catch { self.error = error.localizedDescription }
    }
    func deleteSelected() {
        do { undoIDs = selectedItems.map(\.id); try store.requestDeletion(undoIDs); scheduleUndoExpiry(); selection = []; reload(); status = "已删除，10 秒内可撤销" }
        catch { self.error = error.localizedDescription }
    }
    func undoDelete() {
        do { let restored = try store.undoDeletion(undoIDs); undoIDs = []; status = restored > 0 ? "已恢复 \(restored) 项" : "撤销期已结束，内容未恢复"; reload() }
        catch { self.error = error.localizedDescription }
    }
    private func scheduleUndoExpiry() {
        undoExpiry?.cancel()
        guard let deadline = (try? store.undoableDeletions())?.compactMap(\.pendingDeletion).max() else { undoIDs = []; return }
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for:.seconds(max(0,deadline.timeIntervalSinceNow)+0.1))
            guard !Task.isCancelled, let self else { return }
            self.undoIDs = (try? self.store.undoableDeletions().map(\.id)) ?? []
        }
    }
    func copySelected(plain: Bool = false, paste: Bool = false) { copy(selectedItems, plain: plain, paste: paste) }
    func copy(_ values: [ClipItem], plain: Bool = false, paste: Bool = false, asFiles: Bool = false) {
        guard !values.isEmpty, !settings.conceal, !clipboard.isSuspended else { return }
        guard !isUITest else { error = "界面测试模式不读写系统剪贴板。此操作未执行。"; return }
        do {
            if paste {
                guard AXIsProcessTrusted() else { throw CopyError.unavailable("直接粘贴需要辅助功能权限；仍可使用“复制”后手动粘贴。") }
                guard let target, !target.isTerminated, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw CopyError.unavailable("没有可确认的目标应用，请从目标应用唤出快捷面板") }
            }
            try clipboard.write(values, store: store, plain: plain || ((settings.alwaysPlainText ?? false) && values.allSatisfy { [.text,.richText,.url,.color].contains($0.kind) }), separator: settings.separator, asFiles:asFiles)
            status = "已复制"
            if paste, let target { dispatchPaste(to: target, queueStep: false) }
        } catch { self.error = error.localizedDescription }
    }
    private func dispatchPaste(to destination: NSRunningApplication, queueStep: Bool) {
        hidePanel()
        destination.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if queueStep && queue.state != .preparing { return }
            guard !settings.conceal, !clipboard.isSuspended, !destination.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier, AXIsProcessTrusted() else {
                status = "已复制，但未发送粘贴：目标或权限发生变化"
                if queueStep { queue.failBeforeDispatch(); pauseQueue() }; return
            }
            guard let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                if queueStep { queue.failBeforeDispatch(); pauseQueue() }; return
            }
            hotkeys.unregister(3)
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            status = "粘贴快捷键已发送，目标接收情况需确认"
            if queueStep {
                queue.sent()
                do { try store.setMetadata(queue,key:"queue") }
                catch { queue.cursor = max(0,queue.cursor-1); queue.uncertain(); try? store.setMetadata(queue,key:"queue"); status = "粘贴已发送但队列记录失败，需要人工确认"; return }
            }
            try? await Task.sleep(for: .milliseconds(200))
            if queue.state == .ready { registerQueueKey() }
        }
    }
    func addSelectionToQueue() { appendToQueue(selectedItems.map(\.id)) }
    func appendToQueue(_ ids: [UUID]) { editQueue { try $0.append(ids) } }
    func editQueue(_ change: (inout QueueSession) throws -> Void) {
        do {
            guard queue.canEdit else { throw CopyError.invalid("请先确认上一次发送结果") }
            var updated = queue; try change(&updated)
            try store.setMetadata(updated,key:"queue")
            hotkeys.unregister(3); queue = updated
        } catch { self.error = error.localizedDescription }
    }
    func armQueue() {
        guard !isUITest else { error = "界面测试模式不发送系统粘贴。"; return }
        guard AXIsProcessTrusted() else { error = "顺序粘贴需要辅助功能权限"; return }
        queue.arm(); persistQueue(); if queue.state == .ready { registerQueueKey() }
    }
    private func registerQueueKey() {
        do { try hotkeys.register(id: 3, key: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)) }
        catch { queue.state = .paused; persistQueue(); self.error = error.localizedDescription }
    }
    func pauseQueue() { hotkeys.unregister(3); if queue.state == .preparing || queue.state == .dispatched { queue.uncertain() } else if queue.state != .unknown { queue.state = .paused }; persistQueue() }
    func pasteNext() {
        guard queue.state == .ready, !settings.conceal, !clipboard.isSuspended else { return }
        do {
            guard let destination = NSWorkspace.shared.frontmostApplication, destination.bundleIdentifier != Bundle.main.bundleIdentifier else { throw CopyError.invalid("请在目标应用中按 ⌘V") }
            let id = try queue.begin(); try store.setMetadata(queue,key:"queue")
            guard let item = try store.item(id) else { throw CopyError.notFound }
            try clipboard.write([item], store: store, plain: (settings.alwaysPlainText ?? false) && [.text,.richText,.url,.color].contains(item.kind), separator: settings.separator)
            dispatchPaste(to: destination, queueStep: true)
        } catch { queue.failBeforeDispatch(); pauseQueue(); self.error = error.localizedDescription }
    }
    func persistQueue() { do { try store.setMetadata(queue, key: "queue") } catch { self.error = error.localizedDescription } }
    func maintain() {
        let days = settings.retentionDays, protectedLeases = clipboard.activeLeases.union(dragLeases)
        worker.async { [weak self, store] in
            do { try store.maintain(retentionDays: days); try store.collectExpiredLeases(protecting:protectedLeases) }
            catch { Task { @MainActor in self?.status = error.localizedDescription } }
        }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = error.localizedDescription }
    }
    func exportArchive() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Copy-\(Date().formatted(.iso8601.year().month().day()))"; panel.message = "导出为可读目录，包含剪贴板正文和附件；此导出不加密。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        worker.async { [weak self, store] in
            do { let m = try store.export(to: url); Task { @MainActor in self?.status = "已导出 \(m.items.count) 项；缺少附件 \(m.missingAssets.count) 个；未包含引用文件 \(m.missingFileReferences ?? 0) 个" } }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
    func importArchive() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = "选择含 manifest.json 的 Copy 导出目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try store.inspectImport(from: url, maxBytes: settings.budgetBytes)
            let alert = NSAlert(); alert.messageText = "导入 \(manifest.items.count) 项及 \(manifest.collections.count) 个集合？"; alert.informativeText = "会创建新记录，不覆盖现有内容。同一个导入包重复导入不会重复添加。"; alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let count = try store.importArchive(from: url, budget: settings.budgetBytes); status = "已导入 \(count) 项"; reload()
        } catch { self.error = error.localizedDescription }
    }
    func restoreArchive() {
        let sourcePanel = NSOpenPanel(); sourcePanel.canChooseDirectories = true; sourcePanel.canChooseFiles = false; sourcePanel.message = "从 Copy 导出包恢复为新资料库，原资料库保留"
        guard sourcePanel.runModal() == .OK, let source = sourcePanel.url else { return }
        do {
            let manifest = try store.inspectImport(from:source,maxBytes:settings.budgetBytes)
            let destination = NSSavePanel(); destination.nameFieldStringValue = "Copy-Restored-\(UUID().uuidString.prefix(8))"
            destination.message = "恢复 \(manifest.items.count) 项到一个新目录。使用新资料库身份，采集、同步和外部客户端默认关闭。"
            guard destination.runModal() == .OK, let url = destination.url else { return }
            let restored = try LibraryStore.restoreArchive(from:source,to:url,budget:settings.budgetBytes)
            let alert = NSAlert(); alert.messageText = "恢复完成，共 \(try restored.counts().items) 项"
            alert.informativeText = "原资料库没有被覆盖。可选择下次启动打开恢复库；切换后需重新同意采集和配置系统索引。"
            alert.addButton(withTitle:"下次启动使用恢复库"); alert.addButton(withTitle:"继续使用当前库")
            if alert.runModal() == .alertFirstButtonReturn {
                guard !isUITest else { status = "测试恢复库已生成，界面测试模式不切换正式资料库"; return }
                LibraryLocation.set(url)
                settings.captureEnabled = false; saveSettings(); pauseQueue(); mcp.stop()
                spotlight.synchronize(collectionIDs:[],concealed:true)
                status = "恢复库已设置，请退出并重新打开 Copy；旧库保留在原位置"
            }
        } catch { self.error = error.localizedDescription }
    }
}
