import Foundation
import HomeKit
import Network

/// Loopback-only MCP server (Streamable HTTP, JSON responses) over the HomeKit framework.
///
/// This fork deliberately exposes **organisation** tools only: list homes, rooms and
/// accessories; move accessories between rooms; rename accessories and rooms; add rooms.
/// It has no tools that read or write accessory characteristics (power, locks, doors,
/// thermostats). Device control belongs to Home Assistant.
///
/// Security model: binds to 127.0.0.1 only, rejects any request carrying an `Origin`
/// header and any `Host` header that is not a loopback name, so a web page in a local
/// browser cannot drive it (DNS rebinding / CSRF). There is no authentication beyond
/// "a process on this Mac".
class HTTPMCPServer: NSObject, HMHomeManagerDelegate {
    static let defaultPort: UInt16 = 3040
    static let serverName = "homekit-mcp"
    static let serverVersion = "2.0.0"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private static let maxRequestBytes = 1_048_576
    private static let writeTimeout: TimeInterval = 10

    private let homeManager = HMHomeManager()
    private var homesLoaded = false
    /// Serial numbers read explicitly from the Accessory Information service, keyed by accessory UUID.
    /// `HMCharacteristic.value` is not pre-populated for this characteristic on recent macOS.
    private var serialCache: [UUID: String] = [:]
    let port: UInt16
    private var listener: NWListener?

    override init() {
        let env = ProcessInfo.processInfo.environment["HOMEKIT_MCP_PORT"].flatMap(UInt16.init)
        port = env ?? Self.defaultPort
        super.init()
        log("Starting \(Self.serverName) \(Self.serverVersion) on 127.0.0.1:\(port)")
        homeManager.delegate = self
        startListener()
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - HMHomeManagerDelegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesLoaded = true
        let summary = manager.homes
            .map { "\($0.name) (\($0.accessories.count) accessories, \($0.rooms.count) rooms)" }
            .joined(separator: ", ")
        log("Homes loaded: \(manager.homes.count) [\(summary)]")
        refreshSerialNumbers()
    }

    private func refreshSerialNumbers() {
        var found = 0
        var pending = 0
        var read = 0
        let accessories = homeManager.homes.flatMap(\.accessories)
        for accessory in accessories {
            guard let characteristic = serialCharacteristic(of: accessory) else { continue }
            found += 1
            if let value = characteristic.value as? String, !value.isEmpty {
                serialCache[accessory.uniqueIdentifier] = value
                read += 1
                continue
            }
            pending += 1
            characteristic.readValue { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    pending -= 1
                    if error == nil, let value = characteristic.value as? String, !value.isEmpty {
                        self.serialCache[accessory.uniqueIdentifier] = value
                        read += 1
                    }
                    if pending == 0 {
                        self.log("Serial numbers: \(read) of \(accessories.count) accessories "
                            + "(\(found) expose the characteristic)")
                    }
                }
            }
        }
        if pending == 0 {
            log("Serial numbers: \(read) of \(accessories.count) accessories (\(found) expose the characteristic)")
        }
        if found == 0, let sample = accessories.first {
            let types = sample.services
                .first { $0.serviceType == HMServiceTypeAccessoryInformation }?
                .characteristics.map(\.characteristicType) ?? []
            log("No serial characteristic; Accessory Information of '\(sample.name)' has: \(types)")
        }
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        log("HomeKit authorization status: \(describe(status))")
    }

    // MARK: - Listener

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            log("Invalid port \(port)")
            return
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.log("Listening on 127.0.0.1:\(self?.port ?? 0)")
                case .failed(let error):
                    self?.log("Listener failed: \(error); exiting so launchd restarts us")
                    exit(1)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log("Failed to create listener: \(error); exiting")
            exit(1)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestBytes {
                self.sendPlain(connection, status: 413, message: "Payload Too Large")
                return
            }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.route(request, on: connection)
            case .incomplete where !isComplete:
                self.receive(on: connection, buffer: buffer)
            case .incomplete, .invalid:
                self.sendPlain(connection, status: 400, message: "Bad Request")
            }
        }
    }

    // MARK: - HTTP routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        if request.headers["origin"] != nil {
            log("Rejected \(request.method) \(request.path): Origin header present")
            sendPlain(connection, status: 403, message: "Forbidden")
            return
        }
        if let host = request.headers["host"], !isLoopbackHost(host) {
            log("Rejected \(request.method) \(request.path): Host \(host)")
            sendPlain(connection, status: 403, message: "Forbidden")
            return
        }

        switch (request.method, request.path) {
        case ("POST", "/mcp"):
            handleJSONRPC(request.body, on: connection)
        case ("GET", "/mcp"):
            // No server-initiated SSE stream; the spec allows 405 here.
            sendPlain(connection, status: 405, message: "Method Not Allowed", extraHeaders: ["Allow": "POST"])
        case ("DELETE", "/mcp"):
            sendPlain(connection, status: 405, message: "Method Not Allowed", extraHeaders: ["Allow": "POST"])
        case ("GET", "/"), ("GET", "/health"):
            sendJSON(connection, status: 200, object: healthObject())
        default:
            sendPlain(connection, status: 404, message: "Not Found")
        }
    }

    private func isLoopbackHost(_ hostHeader: String) -> Bool {
        var host = hostHeader.lowercased()
        if host.hasPrefix("[") {
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private func healthObject() -> [String: Any] {
        [
            "status": homesLoaded ? "ok" : "starting",
            "server": Self.serverName,
            "version": Self.serverVersion,
            "authorization": describe(homeManager.authorizationStatus),
            "homes": homeManager.homes.map { ["name": $0.name, "accessories": $0.accessories.count, "rooms": $0.rooms.count] }
        ]
    }

    // MARK: - JSON-RPC

    private func handleJSONRPC(_ body: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            sendJSON(connection, status: 400, object: rpcError(id: NSNull(), code: -32700, message: "Parse error"))
            return
        }
        // Batches are not used by current MCP clients; reject them explicitly.
        guard let message = object as? [String: Any], let method = message["method"] as? String else {
            sendJSON(connection, status: 400, object: rpcError(id: NSNull(), code: -32600, message: "Invalid Request"))
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]

        guard let id = message["id"], !(id is NSNull) else {
            // Notification (e.g. notifications/initialized): acknowledge without a body.
            sendEmpty(connection, status: 202)
            return
        }

        let reply: (Result<[String: Any], RPCFailure>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.sendJSON(connection, status: 200, object: ["jsonrpc": "2.0", "id": id, "result": value])
            case .failure(let failure):
                self.sendJSON(connection, status: 200, object: self.rpcError(id: id, code: failure.code, message: failure.message))
            }
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            reply(.success([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": Self.instructions
            ]))
        case "ping":
            reply(.success([:]))
        case "tools/list":
            reply(.success(["tools": ToolCatalog.tools]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                reply(.failure(RPCFailure(code: -32602, message: "Missing tool name")))
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            callTool(name, arguments: arguments) { outcome in
                reply(.success(outcome.mcpResult))
            }
        default:
            reply(.failure(RPCFailure(code: -32601, message: "Method not found: \(method)")))
        }
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    static let instructions = """
        Apple Home (HomeKit) organisation tools for this household. Use them to read and \
        fix rooms and names in the Apple Home app; they cannot switch, lock or unlock \
        anything (use Home Assistant for device control). Accessories bridged from Home \
        Assistant report their HA entity_id as serial_number, so you can address them by \
        entity_id. Write tools need an exact match (UUID, serial_number or full name); \
        call list_accessories / list_rooms first.
        """

    // MARK: - Tools

    private func callTool(_ name: String, arguments: [String: Any], completion: @escaping (ToolOutcome) -> Void) {
        guard homesLoaded else {
            completion(.failure("HomeKit has not loaded homes yet (authorization: "
                + "\(describe(homeManager.authorizationStatus))). Try again in a few seconds."))
            return
        }
        let args = ToolArguments(arguments)
        do {
            switch name {
            case "list_homes":
                completion(.success(listHomes()))
            case "list_rooms":
                completion(.success(try listRooms(home: args.string("home"))))
            case "list_accessories":
                completion(.success(try listAccessories(
                    home: args.string("home"), room: args.string("room"), query: args.string("query"))))
            case "set_accessory_room":
                let accessoryKey = try args.required("accessory")
                let roomKey = try args.required("room")
                try setAccessoryRoom(accessoryKey, roomKey, home: args.string("home"), completion: completion)
            case "rename_accessory":
                let accessoryKey = try args.required("accessory")
                let newName = try args.requiredName("new_name")
                try renameAccessory(accessoryKey, to: newName, home: args.string("home"), completion: completion)
            case "rename_room":
                let roomKey = try args.required("room")
                let newName = try args.requiredName("new_name")
                try renameRoom(roomKey, to: newName, home: args.string("home"), completion: completion)
            case "add_room":
                let roomName = try args.requiredName("name")
                try addRoom(named: roomName, home: args.string("home"), completion: completion)
            default:
                completion(.failure("Unknown tool: \(name)"))
            }
        } catch let error as ToolError {
            completion(.failure(error.message))
        } catch {
            completion(.failure(error.localizedDescription))
        }
    }

    private func listHomes() -> Any {
        homeManager.homes.map { home in
            [
                "name": home.name,
                "uuid": home.uniqueIdentifier.uuidString,
                "rooms": home.rooms.count,
                "accessories": home.accessories.count
            ] as [String: Any]
        }
    }

    private func listRooms(home homeKey: String?) throws -> Any {
        try homes(matching: homeKey).flatMap { home in
            ([home.roomForEntireHome()] + home.rooms).map { room in
                [
                    "home": home.name,
                    "name": room.name,
                    "uuid": room.uniqueIdentifier.uuidString,
                    "default_room": room.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier,
                    "accessories": home.accessories.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }.count
                ] as [String: Any]
            }
        }
    }

    private func listAccessories(home homeKey: String?, room roomKey: String?, query: String?) throws -> Any {
        var result: [[String: Any]] = []
        for home in try homes(matching: homeKey) {
            let roomFilter = try roomKey.map { try resolveRoom($0, in: home) }
            for accessory in home.accessories {
                if let roomFilter, accessory.room?.uniqueIdentifier != roomFilter.uniqueIdentifier { continue }
                let serial = serialNumber(of: accessory)
                if let query, !query.isEmpty {
                    let needle = query.lowercased()
                    let haystack = [accessory.name, serial ?? "", accessory.room?.name ?? ""].map { $0.lowercased() }
                    if !haystack.contains(where: { $0.contains(needle) }) { continue }
                }
                result.append(describe(accessory, in: home, serial: serial))
            }
        }
        return result
    }

    private func setAccessoryRoom(_ accessoryKey: String, _ roomKey: String, home homeKey: String?,
                                  completion: @escaping (ToolOutcome) -> Void) throws {
        let (home, accessory) = try resolveAccessory(accessoryKey, home: homeKey)
        let room = try resolveRoom(roomKey, in: home)
        let from = accessory.room?.name ?? "(none)"
        if accessory.room?.uniqueIdentifier == room.uniqueIdentifier {
            completion(.success(["changed": false, "accessory": accessory.name, "room": room.name]))
            return
        }
        log("WRITE set_accessory_room \(accessory.name) [\(accessory.uniqueIdentifier)]: \(from) -> \(room.name)")
        perform({ done in home.assignAccessory(accessory, to: room, completionHandler: done) },
                completion: completion) {
            ["changed": true, "accessory": accessory.name, "from": from, "to": room.name]
        }
    }

    private func renameAccessory(_ accessoryKey: String, to newName: String, home homeKey: String?,
                                 completion: @escaping (ToolOutcome) -> Void) throws {
        let (_, accessory) = try resolveAccessory(accessoryKey, home: homeKey)
        let old = accessory.name
        if old == newName {
            completion(.success(["changed": false, "accessory": old]))
            return
        }
        log("WRITE rename_accessory [\(accessory.uniqueIdentifier)]: \(old) -> \(newName)")
        perform({ done in accessory.updateName(newName, completionHandler: done) }, completion: completion) {
            ["changed": true, "from": old, "to": newName, "uuid": accessory.uniqueIdentifier.uuidString]
        }
    }

    private func renameRoom(_ roomKey: String, to newName: String, home homeKey: String?,
                            completion: @escaping (ToolOutcome) -> Void) throws {
        let home = try singleHome(homeKey)
        let room = try resolveRoom(roomKey, in: home)
        let old = room.name
        if old == newName {
            completion(.success(["changed": false, "room": old]))
            return
        }
        log("WRITE rename_room [\(room.uniqueIdentifier)]: \(old) -> \(newName)")
        perform({ done in room.updateName(newName, completionHandler: done) }, completion: completion) {
            ["changed": true, "from": old, "to": newName, "uuid": room.uniqueIdentifier.uuidString]
        }
    }

    private func addRoom(named name: String, home homeKey: String?,
                         completion: @escaping (ToolOutcome) -> Void) throws {
        let home = try singleHome(homeKey)
        if let existing = home.rooms.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            completion(.success(["changed": false, "room": existing.name, "uuid": existing.uniqueIdentifier.uuidString]))
            return
        }
        log("WRITE add_room \(name) in \(home.name)")
        var created: HMRoom?
        perform({ done in
            home.addRoom(withName: name) { room, error in
                created = room
                done(error)
            }
        }, completion: completion) {
            ["changed": true, "room": name, "uuid": created?.uniqueIdentifier.uuidString ?? ""]
        }
    }

    /// Runs a HomeKit write and reports it once, with a timeout so a wedged daemon cannot hang the client.
    private func perform(_ operation: (@escaping (Error?) -> Void) -> Void,
                         completion: @escaping (ToolOutcome) -> Void,
                         success: @escaping () -> Any) {
        var finished = false
        let finish: (ToolOutcome) -> Void = { outcome in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(outcome)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeTimeout) {
            finish(.failure("HomeKit did not answer within \(Int(Self.writeTimeout)) s; "
                + "re-read the state before retrying."))
        }
        operation { error in
            if let error {
                self.log("WRITE failed: \(error.localizedDescription)")
                finish(.failure(error.localizedDescription))
            } else {
                finish(.success(success()))
            }
        }
    }

    // MARK: - Resolution (exact matches only)

    private func homes(matching key: String?) throws -> [HMHome] {
        guard let key, !key.isEmpty else { return homeManager.homes }
        return [try resolveHome(key)]
    }

    private func singleHome(_ key: String?) throws -> HMHome {
        if let key, !key.isEmpty { return try resolveHome(key) }
        guard homeManager.homes.count == 1, let home = homeManager.homes.first else {
            throw ToolError("Several homes exist; pass `home`: "
                + homeManager.homes.map(\.name).joined(separator: ", "))
        }
        return home
    }

    private func resolveHome(_ key: String) throws -> HMHome {
        let matches = homeManager.homes.filter {
            $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || $0.name.caseInsensitiveCompare(key) == .orderedSame
        }
        return try unique(matches, kind: "home", key: key) { $0.name }
    }

    private func resolveRoom(_ key: String, in home: HMHome) throws -> HMRoom {
        let rooms = [home.roomForEntireHome()] + home.rooms
        let matches = rooms.filter {
            $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(key) == .orderedSame
                || $0.name.caseInsensitiveCompare(key) == .orderedSame
        }
        return try unique(matches, kind: "room", key: key) { $0.name }
    }

    private func resolveAccessory(_ key: String, home homeKey: String?) throws -> (HMHome, HMAccessory) {
        var matches: [(HMHome, HMAccessory)] = []
        for home in try homes(matching: homeKey) {
            for accessory in home.accessories {
                let byUUID = accessory.uniqueIdentifier.uuidString.caseInsensitiveCompare(key) == .orderedSame
                let bySerial = serialNumber(of: accessory) == key
                let byName = accessory.name.caseInsensitiveCompare(key) == .orderedSame
                if byUUID || bySerial || byName { matches.append((home, accessory)) }
            }
        }
        return try unique(matches, kind: "accessory", key: key) {
            "\($0.1.name) [\($0.1.uniqueIdentifier.uuidString)] in \($0.1.room?.name ?? "(none)")"
        }
    }

    private func unique<T>(_ matches: [T], kind: String, key: String, label: (T) -> String) throws -> T {
        if matches.count == 1, let match = matches.first { return match }
        if matches.isEmpty {
            throw ToolError("No \(kind) matches '\(key)' exactly (UUID, name"
                + (kind == "accessory" ? " or serial_number" : "") + "). List them first.")
        }
        throw ToolError("'\(key)' matches \(matches.count) \(kind)s; use a UUID: "
            + matches.map(label).joined(separator: "; "))
    }

    // MARK: - Description helpers

    private func describe(_ accessory: HMAccessory, in home: HMHome, serial: String?) -> [String: Any] {
        [
            "home": home.name,
            "name": accessory.name,
            "uuid": accessory.uniqueIdentifier.uuidString,
            "room": accessory.room?.name ?? "(none)",
            "category": accessory.category.localizedDescription,
            "manufacturer": accessory.manufacturer ?? "",
            "model": accessory.model ?? "",
            "serial_number": serial ?? "",
            "firmware": accessory.firmwareVersion ?? "",
            "reachable": accessory.isReachable,
            "bridged": accessory.isBridged
        ]
    }

    /// HAP Serial Number characteristic (0x30). `HMCharacteristicTypeSerialNumber` is deprecated but the
    /// characteristic is still published; Home Assistant's bridge puts the entity_id in it.
    private static let serialNumberCharacteristicType = "00000030-0000-1000-8000-0026BB765291"

    private func serialCharacteristic(of accessory: HMAccessory) -> HMCharacteristic? {
        accessory.services
            .first { $0.serviceType == HMServiceTypeAccessoryInformation }?
            .characteristics
            .first { $0.characteristicType == Self.serialNumberCharacteristicType }
    }

    private func serialNumber(of accessory: HMAccessory) -> String? {
        if let cached = serialCache[accessory.uniqueIdentifier] { return cached }
        return serialCharacteristic(of: accessory)?.value as? String
    }

    private func describe(_ status: HMHomeManagerAuthorizationStatus) -> String {
        if status.contains(.authorized) { return "authorized" }
        if status.contains(.restricted) { return "restricted" }
        if status.contains(.determined) { return "denied" }
        return "not_determined"
    }

    // MARK: - HTTP responses

    private func sendJSON(_ connection: NWConnection, status: Int, object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        send(connection, status: status, contentType: "application/json", body: body)
    }

    private func sendPlain(_ connection: NWConnection, status: Int, message: String,
                           extraHeaders: [String: String] = [:]) {
        send(connection, status: status, contentType: "text/plain; charset=utf-8",
             body: Data(message.utf8), extraHeaders: extraHeaders)
    }

    private func sendEmpty(_ connection: NWConnection, status: Int) {
        send(connection, status: status, contentType: nil, body: Data())
    }

    private func send(_ connection: NWConnection, status: Int, contentType: String?, body: Data,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(HTTPRequest.reason(for: status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp) \(message)")
        fflush(stdout)
    }
}

// MARK: - Supporting types

struct RPCFailure: Error {
    let code: Int
    let message: String
}

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum ToolOutcome {
    case success(Any)
    case failure(String)

    var mcpResult: [String: Any] {
        switch self {
        case .success(let value):
            let text = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
            var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": false]
            if let object = value as? [String: Any] {
                result["structuredContent"] = object
            } else if let array = value as? [Any] {
                result["structuredContent"] = ["items": array]
            }
            return result
        case .failure(let message):
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }
}

struct ToolArguments {
    private let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) -> String? {
        guard let value = values[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument `\(key)`") }
        return value
    }

    func requiredName(_ key: String) throws -> String {
        let value = try required(key)
        guard value.count <= 64 else { throw ToolError("`\(key)` is longer than 64 characters") }
        return value
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        let path = requestLine[1].components(separatedBy: "?").first ?? requestLine[1]
        return .complete(HTTPRequest(method: requestLine[0], path: path, headers: headers, body: body))
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

// MARK: - Tool catalog

enum ToolCatalog {
    private static func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    private static let homeProperty: [String: Any] = [
        "type": "string",
        "description": "Home name or UUID. Optional when only one home exists."
    ]

    private static let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
    private static let idempotentWrite: [String: Any] = [
        "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "list_homes",
            "title": "List homes",
            "description": "List the Apple Home homes this Mac's Apple ID can see, with room and accessory counts.",
            "inputSchema": schema([:]),
            "annotations": readOnly
        ],
        [
            "name": "list_rooms",
            "title": "List rooms",
            "description": "List rooms (including the default room) with UUIDs and accessory counts.",
            "inputSchema": schema(["home": homeProperty]),
            "annotations": readOnly
        ],
        [
            "name": "list_accessories",
            "title": "List accessories",
            "description": "List accessories with room, category, manufacturer, serial_number (the Home Assistant "
                + "entity_id for HA-bridged accessories), reachability and UUID. Optional filters: exact room, "
                + "and a case-insensitive substring `query` over name, serial_number and room.",
            "inputSchema": schema([
                "home": homeProperty,
                "room": ["type": "string", "description": "Exact room name or UUID."],
                "query": ["type": "string", "description": "Substring filter over name, serial_number and room."]
            ]),
            "annotations": readOnly
        ],
        [
            "name": "set_accessory_room",
            "title": "Move accessory to room",
            "description": "Assign an accessory to a room. `accessory` must exactly match a UUID, serial_number "
                + "(HA entity_id) or full name; `room` an exact room name or UUID. Ambiguous matches are refused.",
            "inputSchema": schema([
                "accessory": ["type": "string", "description": "Accessory UUID, serial_number or exact name."],
                "room": ["type": "string", "description": "Exact room name or UUID."],
                "home": homeProperty
            ], required: ["accessory", "room"]),
            "annotations": idempotentWrite
        ],
        [
            "name": "rename_accessory",
            "title": "Rename accessory",
            "description": "Rename an accessory in Apple Home (does not change Home Assistant). `accessory` must "
                + "exactly match a UUID, serial_number or full name.",
            "inputSchema": schema([
                "accessory": ["type": "string", "description": "Accessory UUID, serial_number or exact name."],
                "new_name": ["type": "string", "description": "New name, at most 64 characters."],
                "home": homeProperty
            ], required: ["accessory", "new_name"]),
            "annotations": idempotentWrite
        ],
        [
            "name": "rename_room",
            "title": "Rename room",
            "description": "Rename a room in Apple Home. `room` must exactly match a room name or UUID.",
            "inputSchema": schema([
                "room": ["type": "string", "description": "Exact room name or UUID."],
                "new_name": ["type": "string", "description": "New name, at most 64 characters."],
                "home": homeProperty
            ], required: ["room", "new_name"]),
            "annotations": idempotentWrite
        ],
        [
            "name": "add_room",
            "title": "Add room",
            "description": "Create a room in Apple Home. Returns the existing room if one with that name exists.",
            "inputSchema": schema([
                "name": ["type": "string", "description": "Room name, at most 64 characters."],
                "home": homeProperty
            ], required: ["name"]),
            "annotations": idempotentWrite
        ]
    ]
}
