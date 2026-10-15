import AppIntents
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers
import CopyCore
import CopyStorage
import Foundation

enum LibraryLocation {
    static var current: URL { UserDefaults.standard.url(forKey:"library.location") ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Copy") }
    static func set(_ url: URL) { UserDefaults.standard.set(url,forKey:"library.pendingLocation") }
    static func activatePending() {
        if let url = UserDefaults.standard.url(forKey:"library.pendingLocation") {
            UserDefaults.standard.set(url,forKey:"library.location"); UserDefaults.standard.removeObject(forKey:"library.pendingLocation")
        }
    }
}
enum IntentLibrary {
    static func open() throws -> LibraryStore {
        guard Bundle.main.bundleIdentifier != "dev.neo.Copy.UITest" else { throw CopyError.unavailable("界面测试构建不访问正式自动化资料库") }
        let url = LibraryLocation.current
        guard FileManager.default.fileExists(atPath:url.appendingPathComponent("library.sqlite").path) else { throw CopyError.unavailable("请先启动 Copy 并设置资料库") }
        return try LibraryStore(root:url)
    }
    static func query(_ search: String, collectionID: String?, limit: Int) throws -> [ClipItem] {
        let store = try open(); let settings = try store.metadata(LibrarySettings.self,key:"settings") ?? LibrarySettings()
        guard !settings.conceal else { throw CopyError.permission }
        var id: UUID?
        if let collectionID, !collectionID.isEmpty {
            guard let uuid = UUID(uuidString:collectionID), try store.collections().contains(where: { $0.id == uuid }) else { throw CopyError.notFound }; id = uuid
        }
        var query = SearchQuery(text:search,collectionID:id,historyOnly:id == nil); query.limit = min(20,max(1,limit))
        let items = try store.search(query)
        guard items.reduce(0,{ $0 + $1.text.utf8.count }) <= 5*1024*1024 else { throw CopyError.unavailable("自动化输出超过 5 MiB，请减少数量") }
        guard items.allSatisfy({ !$0.text.isEmpty }) else { throw CopyError.unavailable("所选内容没有文本表示，请在 Copy 中读取附件") }
        return items
    }
}
struct AddTextIntent: AppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var title: LocalizedStringResource = "Add Text to Copy"
    static var description = IntentDescription("Save explicitly provided text in the local Copy library.")
    @Parameter(title:"Text") var text: String
    @Parameter(title:"Collection ID") var collectionID: String?
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = try IntentLibrary.open(), settings = try store.metadata(LibrarySettings.self,key:"settings") ?? LibrarySettings()
        guard !settings.conceal else { throw CopyError.permission }
        var destination: UUID?
        if let raw = collectionID, !raw.isEmpty { guard let id = UUID(uuidString:raw), try store.collections().contains(where: { $0.id == id }) else { throw CopyError.notFound }; destination = id }
        let operation = UUID(), request = ContentRules.digest(Data(text.utf8))
        _ = try store.registerOperation(id:operation,requestHash:request)
        let result = try store.commitOperation(id:operation,requestHash:request) {
            var item = try store.capture(CaptureInput(representations:["public.utf8-plain-text":Data(text.utf8)],text:text,source:"Shortcuts"),budget:settings.budgetBytes,deduplicate:false)
            if let destination { item = try store.update(item.id,expectedRevision:item.revision) { $0.collectionID = destination } }
            return item.id.uuidString
        }
        return .result(value:result.result ?? "")
    }
}
struct SearchCopyIntent: AppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var title: LocalizedStringResource = "Search Copy"
    @Parameter(title:"Query") var query: String
    @Parameter(title:"Collection ID") var collectionID: String?
    @Parameter(title:"Limit",default:20) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> { .result(value:try IntentLibrary.query(query,collectionID:collectionID,limit:limit).map { $0.text }) }
}
struct RecentCopyIntent: AppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var title: LocalizedStringResource = "Get Recent Copy Items"
    @Parameter(title:"Limit",default:1) var limit: Int
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> { .result(value:try IntentLibrary.query("",collectionID:nil,limit:limit).map { $0.text }) }
}
struct CollectionItemIntent: AppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var title: LocalizedStringResource = "Get Copy Collection Item"
    @Parameter(title:"Collection ID") var collectionID: String
    @Parameter(title:"Index (1–20)",default:1) var index: Int
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard (1...20).contains(index) else { throw CopyError.invalid("索引须为 1–20") }
        let items = try IntentLibrary.query("",collectionID:collectionID,limit:index)
        guard items.indices.contains(index-1) else { throw CopyError.notFound }; return .result(value:items[index-1].text)
    }
}
struct OpenCollectionIntent: AppIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var title: LocalizedStringResource = "Open Copy Collection"
    @Parameter(title:"Collection ID") var collectionID: String
    func perform() async throws -> some IntentResult {
        let store = try IntentLibrary.open()
        guard let id = UUID(uuidString:collectionID), try store.collections().contains(where: { $0.id == id }) else { throw CopyError.notFound }
        let opened = await MainActor.run { NSWorkspace.shared.open(URL(string:"copy://collection/\(id.uuidString)")!) }
        guard opened else { throw CopyError.unavailable("无法打开集合") }; return .result()
    }
}
struct CopyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent:RecentCopyIntent(), phrases:["Get recent items from \(.applicationName)"], shortTitle:"Recent Items", systemImageName:"doc.on.clipboard")
    }
}

@MainActor final class SpotlightBridge: ObservableObject {
    @Published var status = "系统索引关闭"
    private var requestedIDs: Set<UUID> = []
    private var requestedConcealment = false
    private var generation = 0
    private let store: LibraryStore
    private var task: Task<Void,Never>?
    init(store: LibraryStore) { self.store = store }
    func synchronize(collectionIDs: Set<UUID>, concealed: Bool) {
        requestedIDs = collectionIDs; requestedConcealment = concealed; generation += 1
        guard task == nil else { return }
        task = Task {
          while true {
            let requestGeneration = generation, collectionIDs = requestedIDs, concealed = requestedConcealment
            status = "正在更新系统索引…"
            do {
                let previous = try store.metadata([String:Int].self,key:"spotlight.revisions") ?? [:]
                var current: [String:Int] = [:], updates: [CSSearchableItem] = []
                if !concealed {
                    for id in collectionIDs {
                        var query = SearchQuery(collectionID:id,historyOnly:false); query.limit = 1000
                        while !Task.isCancelled {
                            let page = try store.search(query)
                            for item in page {
                                current[item.id.uuidString] = item.revision
                                guard previous[item.id.uuidString] != item.revision else { continue }
                                let attrs = CSSearchableItemAttributeSet(contentType:.text)
                                attrs.title = String(item.displayTitle.prefix(100)); attrs.contentDescription = String(item.text.prefix(500)); attrs.textContent = String((item.text+"\n"+item.ocr).prefix(100000))
                                attrs.contentURL = URL(string:"copy://item/\(item.id.uuidString)")
                                updates.append(CSSearchableItem(uniqueIdentifier:item.id.uuidString,domainIdentifier:"dev.neo.Copy",attributeSet:attrs))
                            }
                            if page.count < query.limit { break }; query.offset += query.limit
                        }
                    }
                }
                var intended = previous
                for id in current.keys { intended[id] = 0 }
                // Persist all possibly indexed IDs before the OS write, so a failed/cancelled update remains revocable.
                try store.setMetadata(intended,key:"spotlight.revisions")
                let deleted = Set(previous.keys).subtracting(current.keys)
                if !deleted.isEmpty { try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers:Array(deleted)) }
                if !updates.isEmpty { try await CSSearchableIndex.default().indexSearchableItems(updates) }
                try store.setMetadata(current,key:"spotlight.revisions")
                status = current.isEmpty ? "系统索引已清空" : "已索引 \(current.count) 项"
            } catch { status = "系统索引未完成，请重试；可能仍有待移除内容" }
            if generation == requestGeneration { break }
          }
          task = nil
        }
    }
}
