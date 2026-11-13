import XCTest
import Darwin
@testable import DevIslandCore

final class EditorRoutingTests: XCTestCase {
    func window(_ pids: [Int32], age: Double = 0, folder: String = "/same-project", canFocus: Bool = true) -> EditorWindow {
        let id = UUID().uuidString.lowercased()
        return EditorWindow(windowID: id, socketPath: "/tmp/\(id).sock", token: String(repeating: "a", count: 64), canFocus: canFocus, updatedAt: Date().timeIntervalSince1970 - age,
                            workspaceFolders: [folder], terminals: pids.map { .init(id: UUID().uuidString, processID: $0, name: "same-name") })
    }
    func testExactWindowAndTerminalUseAncestryRegardlessOfNamesAndProject() throws {
        let a = window([101, 102]), b = window([201, 202])
        let selected = try EditorRoutePolicy.select(windows: [a,b], processIDs: [999,202,200])
        XCTAssertEqual(selected.window.windowID, b.windowID); XCTAssertEqual(selected.terminal.processID, 202)
        XCTAssertEqual(try EditorRoutePolicy.select(windows: [a,b], processIDs: [102]).window.windowID, a.windowID)
    }
    func testStaleAmbiguousMissingAndUnavailableSourceNeverGuessByProject() throws {
        func failure(_ windows: [EditorWindow], _ pids: Set<Int32>, _ expected: EditorRoutingError) {
            XCTAssertThrowsError(try EditorRoutePolicy.select(windows: windows, processIDs: pids)) { XCTAssertEqual($0 as? EditorRoutingError, expected) }
        }
        failure([], [101], .missingConnector)
        failure([window([101], age: 46)], [101], .missingConnector)
        failure([window([101])], [], .sourceUnavailable)
        failure([window([101])], [102], .missingTerminal)
        failure([window([101]),window([101])], [101], .ambiguous)
        let now = Date(), future = EditorWindow(windowID: UUID().uuidString, socketPath: "/tmp/test", token: "token", updatedAt: now.addingTimeInterval(30).timeIntervalSince1970, workspaceFolders: [], terminals: [])
        failure([future], [101], .missingConnector)
        let oldEditor = window([101], canFocus: false)
        failure([oldEditor], [101], .editorTooOld)
        failure([window([101], age: 46), oldEditor], [101], .editorTooOld)
        XCTAssertEqual(try EditorRoutePolicy.select(windows: [oldEditor, window([202])], processIDs: [202]).terminal.processID, 202)
    }
    func testSourcePIDBirthTimeProtectsAgainstReuse() throws {
        let info = try XCTUnwrap(ProcessIdentity.read(getpid()))
        let good = SourceApplication(bundleID: TerminalChoice.vscode.rawValue, processID: info.pid, processStart: info.start)
        XCTAssertEqual(ProcessIdentity.ancestors(source: good).first?.pid, info.pid)
        XCTAssertTrue(ProcessIdentity.ancestors(source: .init(processID: info.pid, processStart: info.start + 1)).isEmpty)
        XCTAssertTrue(ProcessIdentity.ancestors(source: .init()).isEmpty)
    }
    func testReplyMustAcknowledgeTheExactRequestWindowTerminalAndFocus() throws {
        let target = EditorTarget(window: window([101]), terminal: .init(id: "terminal", processID: 101, name: "same-name"))
        let request = EditorFocusRequest(target: target)
        func reply(_ extra: [String: Any]) throws -> EditorFocusReply {
            var values: [String: Any] = ["version": 1, "requestID": request.requestID, "windowID": request.windowID, "terminalID": request.terminalID, "ok": true, "selected": true, "windowFocused": true]
            values.merge(extra) { _,new in new }
            return try JSONDecoder().decode(EditorFocusReply.self, from: JSONSerialization.data(withJSONObject: values))
        }
        XCTAssertNoThrow(try EditorRouteClient.validate(reply([:]), request: request))
        for extra in [["requestID":"old"], ["windowID":"other"], ["terminalID":"other"], ["version":2]] as [[String:Any]] {
            XCTAssertThrowsError(try EditorRouteClient.validate(reply(extra), request: request)) { XCTAssertEqual($0 as? EditorRoutingError, .invalidResponse) }
        }
        XCTAssertThrowsError(try EditorRouteClient.validate(reply(["windowFocused":false]), request: request)) { XCTAssertEqual($0 as? EditorRoutingError, .focusFailed) }
    }
    func testSwiftClientAndRealExtensionSocketSelectExactTerminalAndRejectUnsafeRegistry() throws {
        let root = URL(fileURLWithPath: "/tmp/di-routing-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("extensions/vscode/test/fixture.js")
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node",fixture.path,root.path,String(getpid())]; process.standardOutput = output; process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready.flatMap { String(data:$0,encoding:.utf8) }, "READY\n")
        let windows = EditorRegistry.read(root: root), window = try XCTUnwrap(windows.first)
        XCTAssertEqual(windows.count, 1)
        let identity = try XCTUnwrap(ProcessIdentity.read(getpid()))
        var session = AgentSession(id: "routing-test", cwd: "/unrelated/out", lastEvent: Date(), source: .init(bundleID: TerminalChoice.vscode.rawValue, processID: getpid(), processStart: identity.start + 1))
        XCTAssertThrowsError(try EditorRouteClient.focus(session: session, root: root)) { XCTAssertEqual($0 as? EditorRoutingError, .sourceUnavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("focused").path))
        session.source.processStart = identity.start
        let target = try EditorRouteClient.focus(session: session, root: root)
        XCTAssertEqual(target.window.windowID, window.windowID); XCTAssertEqual(target.terminal.processID, getpid())
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("focused"), encoding:.utf8), "correct-terminal")
        let file = root.appendingPathComponent(window.windowID + ".json")
        try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath: file.path)
        XCTAssertTrue(EditorRegistry.read(root: root).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: root.path)
        XCTAssertTrue(EditorRegistry.read(root: root).isEmpty)
    }
}
