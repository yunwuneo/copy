import Foundation
import Network
import Security
import LocalAuthentication
import CopyCore
import CopyStorage

struct ClientGrant: Codable, Identifiable {
    var id = UUID()
    var name: String
    var collections: Set<UUID>
    var history: Bool
    var scopes: Set<String>
    var lastConnection: Date?
    func allows(_ item: ClipItem) -> Bool { (history && item.inHistory) || item.collectionID.map(collections.contains) == true }
}
struct WriteProposal: Identifiable {
    var id: UUID
    var client: UUID
    var clientName: String
    var tool: String
    var arguments: [String: Any]
    var hash: String
    var expires: Date
    var preview: String
}
private enum ClientKeychain {
    static let service = "dev.neo.Copy.MCP"
    static func base(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] }
    static func create(_ id: UUID) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CopyError.unavailable("无法生成客户端令牌") }
        let token = Data(bytes).base64EncodedString()
        var query = base(id); query[kSecValueData as String] = Data(token.utf8); query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CopyError.unavailable("Keychain 无法保存客户端令牌") }; return token
    }
    static func read(_ id: UUID) -> String? {
        var query = base(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne; let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data else { return nil }; return String(data: bytes, encoding: .utf8)
    }
    static func remove(_ id: UUID) { SecItemDelete(base(id) as CFDictionary) }
}

@MainActor final class MCPService: ObservableObject {
    @Published var running = false
    @Published var status = "关闭"
    @Published var clients: [ClientGrant] = []
    @Published var proposals: [WriteProposal] = []
    private let store: LibraryStore
    private var listener: NWListener?
    private let network = DispatchQueue(label: "copy.mcp.network")
    private var connections: [UUID: HTTPConnection] = [:]
    private var expiry: Timer?
    let port: UInt16 = 53647
    init(store: LibraryStore) {
        self.store = store
        clients = (try? store.metadata([ClientGrant].self, key: "mcp.clients")) ?? []
        expiry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.expire() } }
    }
    func createClient(name: String, collections: Set<UUID>, history: Bool, writes: Bool) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, history || !collections.isEmpty else { throw CopyError.invalid("请填写名称并选择至少一个授权范围") }
        var scopes: Set<String> = ["search.metadata","items.read","collections.read"]
        if writes { scopes.formUnion(["items.create","items.update","collections.write"]) }
        let client = ClientGrant(name: name, collections: collections, history: history, scopes: scopes)
        let token = try ClientKeychain.create(client.id)
        do { clients.append(client); try saveClients() } catch { clients.removeAll { $0.id == client.id }; ClientKeychain.remove(client.id); throw error }
        return token
    }
    func revoke(_ id: UUID) {
        clients.removeAll { $0.id == id }; ClientKeychain.remove(id)
        for proposal in proposals where proposal.client == id { try? store.rejectOperation(proposal.id) }
        proposals.removeAll { $0.client == id }; do { try saveClients() } catch { status = "撤销已生效，但授权清单保存失败"; stop() }
    }
    private func saveClients() throws { try store.setMetadata(clients, key: "mcp.clients") }
    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters); self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self else { return }; switch state { case .ready: self.running = true; self.status = "http://127.0.0.1:\(self.port)/mcp"; case .failed: self.stop(); self.status = "监听失败，检查端口占用或系统限制"; default: break }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                guard let self, self.connections.count < 16 else { connection.cancel(); return }
                let id = UUID()
                let client = HTTPConnection(connection: connection, queue: self.network, port: self.port) { [weak self] headers, payload in
                    guard let self, self.running else { return (503,Data()) }; return self.handle(headers: headers, payload: payload)
                } finished: { [weak self] in Task { @MainActor in self?.connections.removeValue(forKey: id) } }
                self.connections[id] = client; client.start()
            } }
            listener.start(queue: network); status = "正在启动…"
        } catch { status = "无法启动本机 MCP" }
    }
    func stop() { listener?.cancel(); listener = nil; for c in connections.values { c.cancel() }; connections = [:]; running = false; status = "关闭" }
    var tokenLookup: (UUID) -> String? = { ClientKeychain.read($0) }
    private func authenticate(_ header: String?) -> ClientGrant? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let supplied = Data(header.dropFirst(7).utf8)
        for client in clients {
            guard let token = tokenLookup(client.id), token.utf8.count == supplied.count else { continue }
            var difference: UInt8 = 0
            for (a,b) in zip(Data(token.utf8),supplied) { difference |= a ^ b }
            if difference == 0 { return client }
        }
        return nil
    }
    func handle(headers: [String: String], payload: Data) -> (Int, Data) {
        guard let client = authenticate(headers["authorization"]) else { return (401,Data()) }
        guard let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return (400,Data()) }
        guard method == "initialize" || headers["mcp-protocol-version"] == "2025-11-25" else { return (400,Data()) }
        if let index = clients.firstIndex(where: { $0.id == client.id }) { clients[index].lastConnection = Date() }
        guard let id = request["id"] else { return method.hasPrefix("notifications/") ? (202,Data()) : (400,Data()) }
        func reply(_ value: [String: Any]) -> (Int,Data) { (200,(try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()) }
        do {
            let result: [String: Any]
            switch method {
            case "initialize": result = ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]], "serverInfo": ["name": "Copy", "version": "0.1.0"]]
            case "ping": result = [:]
            case "tools/list": result = ["tools": Self.toolSchemas]
            case "tools/call":
                guard let parameters = request["params"] as? [String: Any], let name = parameters["name"] as? String else { throw CopyError.invalid("工具参数") }
                let output = try call(name, arguments: parameters["arguments"] as? [String: Any] ?? [:], client: client)
                result = ["content": [["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self)]], "isError": false]
            default: return reply(["jsonrpc":"2.0","id":id,"error":["code":-32601,"message":"Method not found"]])
            }
            return reply(["jsonrpc":"2.0","id":id,"result":result])
        } catch {
            return reply(["jsonrpc":"2.0","id":id,"result":["content":[["type":"text","text": error is CopyError ? error.localizedDescription : "请求未完成"]],"isError":true]])
        }
    }
    private func require(_ scope: String, _ client: ClientGrant) throws { guard client.scopes.contains(scope), clients.contains(where: { $0.id == client.id }) else { throw CopyError.permission } }
    private func authorizedItem(_ args: [String: Any], _ client: ClientGrant) throws -> ClipItem {
        guard let raw = args["itemID"] as? String, let id = UUID(uuidString: raw), let item = try store.item(id), client.allows(item) else { throw CopyError.notFound }; return item
    }
    private func operationJSON(_ op: JournalOperation) -> [String: Any] { ["operationID":op.id.uuidString,"state":op.state,"result":op.result ?? ""] }
    private func call(_ name: String, arguments: [String: Any], client: ClientGrant) throws -> [String: Any] {
        switch name {
        case "search_items":
            try require("search.metadata",client)
            let limit = min(50,max(1,arguments["limit"] as? Int ?? 20)), text = String((arguments["query"] as? String ?? "").prefix(1000))
            var result: [UUID:ClipItem] = [:]
            let filters = arguments["filters"] as? [String:Any] ?? [:]
            var scopes = client.collections.map(Optional.some); if client.history { scopes.append(nil) }
            if let raw = filters["collectionID"] as? String {
                guard let id = UUID(uuidString:raw), client.collections.contains(id) else { throw CopyError.permission }; scopes = [id]
            }
            var cursor: SearchCursor?
            if let raw = arguments["cursor"] as? String {
                guard let data = Data(base64Encoded:raw), let decoded = try? JSONDecoder().decode(SearchCursor.self,from:data) else { throw CopyError.invalid("分页游标") }; cursor = decoded
            }
            for scope in scopes {
                var query = SearchQuery(text:text,collectionID:scope,historyOnly:scope == nil); query.limit = limit+1; query.cursor = cursor; query.useCollectionOrder = false
                if let kinds = filters["kinds"] as? [String] { query.kinds = Set(kinds.compactMap(ClipKind.init(rawValue:))) }
                if let sources = filters["sources"] as? [String] { query.sources = Set(sources) }
                if let from = filters["from"] as? String { guard let date = ISO8601DateFormatter().date(from:from) else { throw CopyError.invalid("from 日期") }; query.from = date }
                if let before = filters["before"] as? String { guard let date = ISO8601DateFormatter().date(from:before) else { throw CopyError.invalid("before 日期") }; query.before = date }
                for item in try store.search(query) where client.allows(item) { result[item.id] = item }
            }
            let ordered = result.values.sorted { $0.captured == $1.captured ? $0.id.uuidString < $1.id.uuidString : $0.captured > $1.captured }
            let page = Array(ordered.prefix(limit))
            var output: [String:Any] = ["items": page.map { ["id":$0.id.uuidString,"title":String($0.displayTitle.prefix(100)),"kind":$0.kind.rawValue,"revision":$0.revision] as [String:Any] }]
            if ordered.count > limit, let last = page.last { output["nextCursor"] = try JSONEncoder().encode(SearchCursor(captured:last.captured,id:last.id)).base64EncodedString() }
            return output
        case "get_item":
            try require("items.read",client); let item = try authorizedItem(arguments,client)
            let type = arguments["representation"] as? String ?? "text"
            let offset = max(0,arguments["offset"] as? Int ?? 0), length = min(256*1024,max(1,arguments["length"] as? Int ?? 64*1024))
            var bytes: Data
            if type == "text" { bytes = Data(item.text.utf8) }
            else {
                guard let rep = item.representations.first(where:{ $0.type == type }) else { throw CopyError.notFound }
                bytes = try store.data(for:rep)
                if type == "com.copy.file-list" { bytes = try FileReference.portable(bytes).data }
            }
            guard offset <= bytes.count else { throw CopyError.invalid("附件偏移量") }
            let end = min(bytes.count,offset+length), chunk = bytes.subdata(in:offset..<end)
            return ["id":item.id.uuidString,"title":item.title,"revision":item.revision,"representation":type,"representations":item.representations.map(\.type),"encoding":"base64","data":chunk.base64EncodedString(),"offset":offset,"totalBytes":bytes.count,"nextOffset":end,"complete":end == bytes.count,"sha256":ContentRules.digest(bytes)]
        case "list_collections":
            try require("collections.read",client)
            return ["collections": try store.collections().filter { client.collections.contains($0.id) }.map { ["id":$0.id.uuidString,"name":$0.name,"baseHash":try Self.collectionHash($0)] }]
        case "get_operation":
            guard let raw = arguments["operationID"] as? String, let id = UUID(uuidString: raw), try store.metadata(UUID.self, key: "operationOwner.\(id)") == client.id, let op = try store.operation(id) else { throw CopyError.notFound }
            return operationJSON(op)
        case "create_item", "update_item", "move_item", "delete_item", "create_collection", "update_collection", "delete_collection":
            try validateWrite(name, arguments, client)
            guard let raw = arguments["operationID"] as? String, let id = UUID(uuidString: raw) else { throw CopyError.invalid("operationID 必须为 UUID") }
            let canonical = try JSONSerialization.data(withJSONObject: ["client":client.id.uuidString,"tool":name,"arguments":arguments], options: [.sortedKeys])
            let hash = ContentRules.digest(canonical)
            let operation = try store.registerOperation(id: id, requestHash: hash)
            try store.setMetadata(client.id, key: "operationOwner.\(id)")
            if operation.state == "pending", !proposals.contains(where: { $0.id == id }) {
                guard proposals.count < 50 else { throw CopyError.unavailable("待审批请求过多") }
                proposals.append(WriteProposal(id: id, client: client.id, clientName: client.name, tool: name, arguments: arguments, hash: hash, expires: Date().addingTimeInterval(300), preview: String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self)))
            }
            return operationJSON(operation)
        default: throw CopyError.invalid("未知工具")
        }
    }
    private func validateWrite(_ tool: String, _ args: [String:Any], _ client: ClientGrant) throws {
        if tool.contains("collection") { try require("collections.write",client) }
        else { try require(tool == "create_item" ? "items.create" : "items.update",client) }
        if ["update_item","move_item","delete_item"].contains(tool) {
            let item = try authorizedItem(args,client)
            guard args["baseRevision"] as? Int == item.revision else { throw CopyError.conflict }
        }
        if ["create_item","move_item"].contains(tool) {
            if let raw = args["collectionID"] as? String {
                guard let id = UUID(uuidString: raw), client.collections.contains(id), try store.collections().contains(where: { $0.id == id }) else { throw CopyError.permission }
            } else if !client.history { throw CopyError.permission }
        }
        if ["update_collection","delete_collection"].contains(tool) {
            guard let raw = args["collectionID"] as? String, let id = UUID(uuidString: raw), client.collections.contains(id), try store.collections().contains(where: { $0.id == id }) else { throw CopyError.permission }
            // Collections have no revision field yet: bind approval to an exact content hash.
            let c = try store.collections().first(where: { $0.id == id })!
            let hash = try Self.collectionHash(c)
            guard args["baseHash"] as? String == hash else { throw CopyError.conflict }
        }
        if ["create_item","update_item"].contains(tool) { guard let text = args["text"] as? String, text.utf8.count <= 512 * 1024 else { throw CopyError.invalid("text 必须存在且不超过 512 KiB") } }
        if ["create_collection","update_collection"].contains(tool) { guard let name = args["name"] as? String, !name.isEmpty, name.count <= 100 else { throw CopyError.invalid("集合名称") } }
    }
    func approve(_ proposal: WriteProposal, budget: Int64) {
        do {
            guard proposal.expires > Date(), proposals.contains(where: { $0.id == proposal.id && $0.hash == proposal.hash }), let client = clients.first(where: { $0.id == proposal.client }) else { throw CopyError.permission }
            try validateWrite(proposal.tool,proposal.arguments,client)
            let args = proposal.arguments
            _ = try store.commitOperation(id: proposal.id, requestHash: proposal.hash) {
                switch proposal.tool {
                case "create_item":
                    let text = args["text"] as! String
                    var item = try store.capture(CaptureInput(representations: ["public.utf8-plain-text":Data(text.utf8)],text:text,source:"MCP"),budget:budget,deduplicate:false)
                    if let raw = args["collectionID"] as? String, let id = UUID(uuidString: raw) { item = try store.update(item.id,expectedRevision:item.revision) { $0.collectionID = id } }
                    return item.id.uuidString
                case "update_item":
                    let item = try authorizedItem(args,client)
                    return try store.editText(item.id,expectedRevision:item.revision,title:args["title"] as? String ?? item.title,text:args["text"] as! String,budget:budget).id.uuidString
                case "move_item":
                    let item = try authorizedItem(args,client)
                    let destination = (args["collectionID"] as? String).flatMap(UUID.init(uuidString:))
                    if destination == nil {
                        let settings = try store.metadata(LibrarySettings.self,key:"settings") ?? LibrarySettings()
                        let review = try store.unpinReview([item.id],days:settings.retentionDays)
                        guard review.onlyPinned == 0 else { throw CopyError.invalid("此项已过历史保留期，请在 Copy 中确认取消收藏或转移集合") }
                        _ = try store.unpin([item.id],expectedToken:review.token,days:settings.retentionDays)
                    } else { try store.moveItems([item],to:destination) }
                    return item.id.uuidString
                case "delete_item": let item = try authorizedItem(args,client); try store.requestDeletion([item.id]); return item.id.uuidString
                case "create_collection":
                    let c = ClipCollection(name:args["name"] as! String); try store.saveCollection(c); return c.id.uuidString
                case "update_collection":
                    let id = UUID(uuidString:args["collectionID"] as! String)!
                    var c = try store.collections().first(where: { $0.id == id })!; c.name = args["name"] as! String; try store.saveCollection(c); return c.id.uuidString
                case "delete_collection":
                    let id = UUID(uuidString:args["collectionID"] as! String)!; try store.deleteCollection(id,keepOrphansInHistory:true); return id.uuidString
                default: throw CopyError.invalid("未知写操作")
                }
            }
            status = "已提交审批操作"; proposals.removeAll { $0.id == proposal.id }
        } catch { status = "审批未提交：\(error.localizedDescription)" }
    }
    func reject(_ proposal: WriteProposal) { try? store.rejectOperation(proposal.id); proposals.removeAll { $0.id == proposal.id } }
    private func expire() { for p in proposals where p.expires <= Date() { try? store.rejectOperation(p.id) }; proposals.removeAll { $0.expires <= Date() } }
    static func collectionHash(_ collection: ClipCollection) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return ContentRules.digest(try encoder.encode(collection)) }
    static var toolSchemas: [[String:Any]] {
        let specs: [(String,[String], [String])] = [
            ("search_items",["query","limit","cursor","filters"],[]), ("get_item",["itemID","representation","offset","length"],["itemID"]), ("list_collections",[],[]),
            ("get_operation",["operationID"],["operationID"]),
            ("create_item",["operationID","text","collectionID"],["operationID","text"]),
            ("update_item",["operationID","itemID","baseRevision","text","title"],["operationID","itemID","baseRevision","text"]),
            ("move_item",["operationID","itemID","baseRevision","collectionID"],["operationID","itemID","baseRevision"]),
            ("delete_item",["operationID","itemID","baseRevision"],["operationID","itemID","baseRevision"]),
            ("create_collection",["operationID","name"],["operationID","name"]),
            ("update_collection",["operationID","collectionID","baseHash","name"],["operationID","collectionID","baseHash","name"]),
            ("delete_collection",["operationID","collectionID","baseHash"],["operationID","collectionID","baseHash"])
        ]
        return specs.map { name,fields,required in
            var props: [String:Any] = Dictionary(uniqueKeysWithValues: fields.map { ($0,["type":["limit","baseRevision","offset","length"].contains($0) ? "integer" : "string"]) })
            if fields.contains("filters") { props["filters"] = ["type":"object","properties":["collectionID":["type":"string"],"from":["type":"string"],"before":["type":"string"],"kinds":["type":"array","items":["type":"string"]],"sources":["type":"array","items":["type":"string"]]],"additionalProperties":false] }
            return ["name":name,"description": "Copy scoped tool. Writes return pending and require approval in Copy; poll get_operation. get_item returns bounded base64 chunks and nextOffset; local file bookmarks are removed. No scripts or direct paste.","inputSchema":["type":"object","properties":props,"required":required,"additionalProperties":false]]
        }
    }
}

/// Bounded, single-request HTTP/1.1 transport. It never listens on an external interface.
// Mutable transport state is confined to the serial network queue.
final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let port: UInt16
    let handler: @MainActor ([String:String],Data) -> (Int,Data)
    let finished: () -> Void
    private var buffer = Data()
    private var closed = false
    private var didFinish = false
    init(connection: NWConnection, queue: DispatchQueue, port: UInt16, handler: @escaping @MainActor ([String:String],Data) -> (Int,Data), finished: @escaping () -> Void) { self.connection = connection; self.queue = queue; self.port = port; self.handler = handler; self.finished = finished }
    func start() { connection.start(queue:queue); queue.asyncAfter(deadline:.now()+10) { [weak self] in self?.cancel() }; read() }
    func cancel() { queue.async { guard !self.didFinish else { return }; self.didFinish = true; self.closed = true; self.connection.cancel(); self.finished() } }
    private func read() {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 1024*1024 else { self.respond(413,Data()); return }
            if self.parse() { return }
            if complete || error != nil { self.cancel() } else { self.read() }
        }
    }
    private func parse() -> Bool {
        guard let boundary = buffer.range(of:Data("\r\n\r\n".utf8)) else { if buffer.count > 16384 { respond(400,Data()); return true }; return false }
        guard boundary.lowerBound <= 16384, let head = String(data:buffer[..<boundary.lowerBound],encoding:.utf8) else { respond(400,Data()); return true }
        let lines = head.components(separatedBy:"\r\n"), request = lines[0].split(separator:" ")
        guard request.count == 3, request[1] == "/mcp", request[2] == "HTTP/1.1" else { respond(400,Data()); return true }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":") else { respond(400,Data()); return true }
            let key = line[..<colon].lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard headers[key] == nil else { respond(400,Data()); return true }; headers[key] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil else { respond(403,Data()); return true }
        guard request[0] == "POST" else { respond(405,Data()); return true }
        guard headers["accept"]?.contains("application/json") == true, headers["accept"]?.contains("text/event-stream") == true, headers["transfer-encoding"] == nil, headers["content-type"]?.hasPrefix("application/json") == true, let lengthText = headers["content-length"], let length = Int(lengthText), (1...900000).contains(length) else { respond(400,Data()); return true }
        let available = buffer.count-boundary.upperBound
        guard available >= length else { return false }
        guard available == length else { respond(400,Data()); return true }
        let payload = Data(buffer[boundary.upperBound...]); buffer = Data()
        Task { @MainActor in let response = handler(headers,payload); queue.async { self.respond(response.0,response.1) } }
        return true
    }
    private func respond(_ code: Int, _ body: Data) {
        guard !closed else { return }; closed = true
        let phrase = [200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",405:"Method Not Allowed",413:"Content Too Large",503:"Unavailable"][code] ?? "Error"
        var output = Data("HTTP/1.1 \(code) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8); output.append(body)
        connection.send(content:output,completion:.contentProcessed { [weak self] _ in self?.cancel() })
    }
}
