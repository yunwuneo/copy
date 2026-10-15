import AppKit
import Carbon
import CopyCore
import CopyStorage
import Vision
import UniformTypeIdentifiers

struct PasteboardBundle: Codable { var items: [[String: Data]] }

@MainActor final class ClipboardDriver {
    private var timer: Timer?
    private var lastChange = -1
    private var ownChange = -1
    private var locked = false
    var isSuspended: Bool { locked }
    var settings: () -> LibrarySettings = { LibrarySettings() }
    var onCapture: (CaptureInput) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var activeLeases: Set<URL> = []
    var onExternalChange: () -> Void = {}
    private var observers: [NSObjectProtocol] = []
    func start() {
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.locked = note.name.rawValue.hasSuffix("IsLocked"); self?.lastChange = NSPasteboard.general.changeCount }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.locked = true } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lastChange = NSPasteboard.general.changeCount } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lastChange = NSPasteboard.general.changeCount } })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in MainActor.assumeIsolated { self?.locked = note.name == NSWorkspace.sessionDidResignActiveNotification; self?.lastChange = NSPasteboard.general.changeCount } })
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func poll() {
        let pb = NSPasteboard.general, current = pb.changeCount
        guard current != lastChange else { return }
        lastChange = current
        if current != ownChange { activeLeases = []; onExternalChange() }
        let config = settings()
        guard !locked, config.allowsCapture(), current != ownChange else { return }
        let observedApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard observedApp != Bundle.main.bundleIdentifier, !config.excludedApps.contains(observedApp ?? "") else { return }
        do { if let input = try Self.read(pb), pb.changeCount == current { onCapture(input) } } catch { onError(error.localizedDescription) }
    }
    /// Reading a named test pasteboard exercises serialization without touching the user's clipboard.
    static func read(_ pb: NSPasteboard) throws -> CaptureInput? {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return nil }
        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })
        guard allTypes.isDisjoint(with: ContentRules.excludedTypes) else { return nil }
        if allTypes.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            var refs: [FileReference] = [], representations: [String: Data] = [:]
            var snapshotBytes = 0
            for item in items {
                guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL else { throw CopyError.invalid("混合文件复制无法无损采集") }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                var ref = FileReference(name: url.lastPathComponent, bookmark: try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), status: "仅引用")
                if values?.isRegularFile == true, let size = values?.fileSize, size <= 20 * 1024 * 1024, snapshotBytes + size <= 50 * 1024 * 1024, let data = try? Data(contentsOf: url) {
                    let key = "com.copy.file-snapshot.\(UUID().uuidString)"
                    representations[key] = data; snapshotBytes += data.count; ref.snapshotType = key; ref.status = "已保存快照"
                }
                refs.append(ref)
            }
            representations["com.copy.file-list"] = try JSONEncoder().encode(refs)
            return CaptureInput(representations: representations, text: refs.map(\.name).joined(separator: "\n"), kind: .files)
        }
        var payloads: [[String: Data]] = [], total = 0
        for item in items {
            var payload: [String: Data] = [:]
            for type in item.types where !type.rawValue.hasPrefix("com.apple.pasteboard.promised") {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                total += data.count
                guard data.count <= 20 * 1024 * 1024, total <= 50 * 1024 * 1024 else { throw CopyError.invalid("剪贴板载荷超限，未保存") }
                payload[type.rawValue] = data
            }
            guard !payload.isEmpty else { throw CopyError.invalid("内容仅提供延迟表示，暂不能保存") }
            payloads.append(payload)
        }
        let text = items.compactMap { $0.string(forType: .string) }.joined(separator: "\n")
        if payloads.count == 1 { return CaptureInput(representations: payloads[0], text: text) }
        return CaptureInput(representations: ["com.copy.pasteboard-bundle": try JSONEncoder().encode(PasteboardBundle(items: payloads))], text: text, kind: ContentRules.kind(types: allTypes, text: text))
    }
    func write(_ items: [ClipItem], store: LibraryStore, plain: Bool, separator: String, asFiles: Bool = false) throws {
        let pb = NSPasteboard.general
        let writers = try Self.writers(items, store: store, plain: plain, separator: separator, asFiles:asFiles)
        guard !writers.isEmpty else { throw CopyError.invalid("没有可写入内容") }
        pb.clearContents()
        guard pb.writeObjects(writers) else { throw CopyError.unavailable("写入系统剪贴板失败") }
        ownChange = pb.changeCount; lastChange = ownChange
        activeLeases = Set(writers.compactMap { ($0 as? NSURL).map { $0 as URL } }.filter { $0.path.hasPrefix(store.root.appendingPathComponent("leases").path + "/") })
        try store.setMetadata(activeLeases,key:"clipboard.leases")
    }
    static func writers(_ items: [ClipItem], store: LibraryStore, plain: Bool, separator: String, asFiles: Bool = false) throws -> [NSPasteboardWriting] {
        guard !asFiles || items.allSatisfy({ $0.kind == .image || $0.kind == .files }) else { throw CopyError.invalid("作为文件输出仅支持图片和文件；未输出任何内容") }
        if !plain, items.count > 1, items.allSatisfy({ [.text,.richText,.url,.color].contains($0.kind) }), items.contains(where:{ $0.kind == .richText }) {
            let merged = NSMutableAttributedString(string:"")
            for (index,item) in items.enumerated() {
                if index > 0 { merged.append(NSAttributedString(string:separator)) }
                if item.kind == .richText {
                    guard let rep = item.representations.first(where:{ $0.type == "public.rtf" }) else { throw CopyError.invalid("批量富文本合并需要 RTF 表示；请逐项复制或明确选择纯文本") }
                    merged.append(try SafeRichText.rtf(store.data(for:rep)))
                } else { merged.append(NSAttributedString(string:item.text)) }
            }
            let object = NSPasteboardItem()
            object.setData(try merged.data(from:NSRange(location:0,length:merged.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf]),forType:.rtf)
            object.setString(merged.string,forType:.string)
            return [object]
        }
        if plain || (items.count > 1 && items.allSatisfy({ [.text, .url, .color].contains($0.kind) })) {
            guard items.allSatisfy({ !$0.text.isEmpty }) else { throw CopyError.invalid("含非文本内容，无法转换为纯文本") }
            return [items.map(\.text).joined(separator: separator) as NSString]
        }
        var result: [NSPasteboardWriting] = []
        for item in items {
            if asFiles, item.kind == .image {
                let preference = ["com.compuserve.gif","public.png","public.jpeg","public.heic","public.tiff"]
                guard let rep = preference.compactMap({ type in item.representations.first { $0.type == type } }).first else { throw CopyError.invalid("没有可作为文件输出的原始图像表示") }
                let suffix = UTType(rep.type)?.preferredFilenameExtension ?? "image"
                let budget = try store.metadata(LibrarySettings.self,key:"settings")?.budgetBytes ?? 512*1024*1024
                let file = try store.createLease(data:store.data(for:rep),name:"Copy-\(item.id.uuidString.prefix(8)).\(suffix)",budget:budget)
                result.append(file as NSURL)
            } else if item.kind == .files {
                guard let rep = item.representations.first(where: { $0.type == "com.copy.file-list" }) else { throw CopyError.invalid("缺少文件清单") }
                let refs = try JSONDecoder().decode([FileReference].self, from: store.data(for: rep))
                let budget = try store.metadata(LibrarySettings.self,key:"settings")?.budgetBytes ?? 512*1024*1024
                for ref in refs {
                    if let type = ref.snapshotType, let snapshot = item.representations.first(where: { $0.type == type }) {
                        let file = try store.createLease(data:store.data(for:snapshot),name:ref.name,budget:budget)
                        result.append(file as NSURL)
                    } else if let bookmark = ref.bookmark {
                        var stale = false
                        let file = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                        guard !stale, FileManager.default.fileExists(atPath: file.path) else { throw CopyError.unavailable("引用文件已失效：\(ref.name)") }
                        result.append(file as NSURL)
                    } else { throw CopyError.unavailable("引用文件不可用：\(ref.name)") }
                }
            } else if let bundled = item.representations.first(where: { $0.type == "com.copy.pasteboard-bundle" }) {
                let bundle = try JSONDecoder().decode(PasteboardBundle.self, from: store.data(for: bundled))
                for payload in bundle.items { let object = NSPasteboardItem(); for (type,data) in payload { object.setData(data, forType: .init(type)) }; result.append(object) }
            } else {
                let object = NSPasteboardItem()
                for rep in item.representations { object.setData(try store.data(for: rep), forType: .init(rep.type)) }
                result.append(object)
            }
        }
        return result
    }
}

final class GlobalHotkeys {
    private var handler: EventHandlerRef?
    private var keys: [UInt32: EventHotKeyRef] = [:]
    var action: (UInt32) -> Void = { _ in }
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue().action(identifier.id)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(id: UInt32, key: UInt32, modifiers: UInt32) throws {
        unregister(id)
        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x43505931, id: id), GetApplicationEventTarget(), 0, &ref)
        guard result == noErr, let ref else { throw CopyError.unavailable("快捷键注册失败或冲突（\(result)）") }
        keys[id] = ref
    }
    func unregister(_ id: UInt32) { if let key = keys.removeValue(forKey: id) { UnregisterEventHotKey(key) } }
    deinit { for key in keys.values { UnregisterEventHotKey(key) }; if let handler { RemoveEventHandler(handler) } }
}

enum OCRService {
    static func recognize(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
