import Foundation
import Darwin
import CDevIsland

public struct EditorTerminal: Codable, Equatable {
    public let id: String
    public let processID: Int32
    public let name: String
    public init(id: String, processID: Int32, name: String) { self.id = id; self.processID = processID; self.name = name }
}
public struct EditorWindow: Codable, Equatable {
    public let version: Int
    public let windowID: String
    public let bundleID: String
    public let socketPath: String
    public let token: String
    public let canFocus: Bool
    public let updatedAt: Double
    public let workspaceFolders: [String]
    public let terminals: [EditorTerminal]
    public init(version: Int = 1, windowID: String, bundleID: String = TerminalChoice.vscode.rawValue, socketPath: String,
                token: String, canFocus: Bool = true, updatedAt: Double, workspaceFolders: [String], terminals: [EditorTerminal]) {
        self.version = version; self.windowID = windowID; self.bundleID = bundleID; self.socketPath = socketPath
        self.token = token; self.canFocus = canFocus; self.updatedAt = updatedAt; self.workspaceFolders = workspaceFolders; self.terminals = terminals
    }
}
public struct EditorTarget: Equatable {
    public let window: EditorWindow
    public let terminal: EditorTerminal
}
public enum EditorRoutingError: Error, Equatable {
    case missingConnector, editorTooOld, sourceUnavailable, missingTerminal, ambiguous, unavailable, invalidResponse, focusFailed
}
public enum EditorRoutePolicy {
    public static func select(windows: [EditorWindow], processIDs: Set<Int32>, now: Date = Date()) throws -> EditorTarget {
        let connected = windows.filter { $0.version == 1 && $0.bundleID == TerminalChoice.vscode.rawValue &&
            now.timeIntervalSince1970 - $0.updatedAt <= 45 && $0.updatedAt <= now.timeIntervalSince1970 + 5 }
        guard !connected.isEmpty else { throw EditorRoutingError.missingConnector }
        // A live connector without workbench.action.focusWindow means the VS Code build is too old, not that the extension is missing.
        let current = connected.filter(\.canFocus)
        guard !current.isEmpty else { throw EditorRoutingError.editorTooOld }
        guard !processIDs.isEmpty else { throw EditorRoutingError.sourceUnavailable }
        let matches = current.flatMap { window in window.terminals.filter { processIDs.contains($0.processID) }.map { EditorTarget(window: window, terminal: $0) } }
        guard !matches.isEmpty else { throw EditorRoutingError.missingTerminal }
        guard matches.count == 1 else { throw EditorRoutingError.ambiguous }
        return matches[0]
    }
}
public enum EditorRegistry {
    public static var root: URL { URL(fileURLWithPath: "/tmp/dev-island-vscode-\(getuid())", isDirectory: true) }
    private static func owned(_ url: URL, type: FileAttributeType, maximum: UInt64? = nil) -> Bool {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path), attr[.type] as? FileAttributeType == type,
              (attr[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attr[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { return false }
        return maximum.map { ((attr[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= $0 } ?? true
    }
    public static func read(root: URL = root) -> [EditorWindow] {
        guard owned(root, type: .typeDirectory) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(128).compactMap { url in
            guard owned(url, type: .typeRegular, maximum: 65536), let data = try? Data(contentsOf: url),
                  let window = try? JSONDecoder().decode(EditorWindow.self, from: data),
                  UUID(uuidString: window.windowID) != nil,
                  url.deletingPathExtension().lastPathComponent.lowercased() == window.windowID.lowercased(),
                  window.token.count == 64, window.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  window.workspaceFolders.count <= 64, window.terminals.count <= 256,
                  window.terminals.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.processID > 1 && $0.name.count <= 160 }),
                  window.socketPath == root.appendingPathComponent(window.windowID + ".sock").path,
                  owned(URL(fileURLWithPath: window.socketPath), type: .typeSocket) else { return nil }
            return window
        }
    }
}
public struct EditorFocusRequest: Encodable {
    public let version = 1
    public let action = "focus"
    public let requestID: String
    public let windowID: String
    public let terminalID: String
    public let processID: Int32
    public let token: String
    public init(target: EditorTarget, requestID: String = UUID().uuidString) {
        self.requestID = requestID; windowID = target.window.windowID; terminalID = target.terminal.id
        processID = target.terminal.processID; token = target.window.token
    }
}
public struct EditorFocusReply: Codable {
    public let version: Int
    public let requestID: String?
    public let windowID: String?
    public let terminalID: String?
    public let ok: Bool
    public let selected: Bool?
    public let windowFocused: Bool?
    public let error: String?
}
public enum EditorRouteClient {
    /// Call off the UI thread. The source PID birth time is checked before any editor is contacted.
    public static func focus(session: AgentSession, root: URL = EditorRegistry.root) throws -> EditorTarget {
        let windows = EditorRegistry.read(root: root)
        let ancestors = ProcessIdentity.ancestors(source: session.source)
        let target = try EditorRoutePolicy.select(windows: windows, processIDs: Set(ancestors.map(\.pid)))
        try focus(target: target)
        return target
    }
    public static func focus(target: EditorTarget) throws {
        let request = EditorFocusRequest(target: target)
        var bytes = try JSONEncoder().encode(request); bytes.append(10)
        var buffer = [UInt8](repeating: 0, count: 8192)
        let size = bytes.withUnsafeBytes { data in di_socket_request(target.window.socketPath, data.baseAddress, data.count, &buffer, buffer.count, 1500) }
        guard size > 0 else { throw EditorRoutingError.unavailable }
        let reply = try? JSONDecoder().decode(EditorFocusReply.self, from: Data(buffer.prefix(Int(size))))
        try validate(reply, request: request)
    }
    static func validate(_ reply: EditorFocusReply?, request: EditorFocusRequest) throws {
        guard let reply, reply.version == 1, reply.requestID == request.requestID,
              reply.windowID == request.windowID, reply.terminalID == request.terminalID else { throw EditorRoutingError.invalidResponse }
        guard reply.ok, reply.selected == true, reply.windowFocused == true else { throw EditorRoutingError.focusFailed }
    }
}
