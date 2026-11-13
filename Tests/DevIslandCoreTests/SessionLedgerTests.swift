import XCTest
@testable import DevIslandCore

final class SessionLedgerTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ kind: EventKind, at offset: Double, session: String = "session-a", call: String? = nil,
               tool: String? = nil, agent: String? = nil) -> AgentEvent {
        AgentEvent(sessionID: session, timestamp: base.addingTimeInterval(offset), kind: kind, cwd: "/Projects/App",
                   toolCallID: call, toolName: tool, agentID: agent)
    }
    func testQuestionWaitSurvivesUnrelatedToolsAndAcknowledgement() {
        var ledger = SessionLedger()
        ledger.apply(event(.prompt, at: 0))
        XCTAssertEqual(ledger.apply(event(.question, at: 1, call: "q", tool: "AskUserQuestion")), .question)
        ledger.apply(event(.toolStarted, at: 2, call: "bash", tool: "Bash"))
        ledger.apply(event(.toolFinished, at: 3, call: "bash", tool: "Bash"))
        ledger.sessions["session-a"]?.snoozedUntil = base.addingTimeInterval(300)
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .question)
        ledger.apply(event(.toolFinished, at: 4, call: "q", tool: "AskUserQuestion"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testDelayedPermissionNotificationIsOneInteraction() {
        var ledger = SessionLedger()
        XCTAssertEqual(ledger.apply(event(.permission, at: 1, call: "p", tool: "Bash")), .permission)
        XCTAssertNil(ledger.apply(event(.permission, at: 7)))
        XCTAssertEqual(ledger.sessions["session-a"]?.pending.count, 1)
        ledger.apply(event(.toolFinished, at: 8, call: "p", tool: "Bash"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testQuestionPermissionKeepsQuestionLabel() {
        var ledger = SessionLedger()
        ledger.apply(event(.question, at: 1, call: "q", tool: "AskUserQuestion"))
        XCTAssertNil(ledger.apply(event(.permission, at: 2, call: "q", tool: "AskUserQuestion")))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .question)
    }
    func testParallelAgentsNeedTheirOwnCompletion() {
        var ledger = SessionLedger()
        ledger.apply(event(.permission, at: 1, call: "p", tool: "Bash", agent: "child"))
        ledger.apply(event(.toolFinished, at: 2, call: "p", tool: "Bash"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .permission)
        ledger.apply(event(.toolFinished, at: 3, call: "p", tool: "Bash", agent: "child"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testNewPromptClearsWaitingAndRejectsLatePriorEvent() {
        var ledger = SessionLedger()
        ledger.apply(event(.question, at: 1, call: "q"))
        ledger.apply(event(.prompt, at: 4))
        XCTAssertNil(ledger.apply(event(.question, at: 2, call: "q")))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testRetiredToolCannotBecomeWaitingAgain() {
        var ledger = SessionLedger()
        ledger.apply(event(.permission, at: 1, call: "p", tool: "Bash"))
        ledger.apply(event(.toolFinished, at: 2, call: "p", tool: "Bash"))
        XCTAssertNil(ledger.apply(event(.permission, at: 3, call: "p", tool: "Bash")))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testDuplicateIDDoesNotRepeatOrRegress() {
        var ledger = SessionLedger()
        let question = event(.question, at: 1)
        ledger.apply(question)
        XCTAssertNil(ledger.apply(question))
        XCTAssertEqual(ledger.history.count, 1)
    }
    func testSameProjectHasTenIndependentSessions() {
        var ledger = SessionLedger()
        for i in 0..<10 { ledger.apply(event(i % 2 == 0 ? .question : .prompt, at: Double(i), session: "s-\(i)")) }
        XCTAssertEqual(ledger.sessions.count, 10)
        XCTAssertEqual(ledger.sortedSessions.filter { $0.state == .question }.count, 5)
    }
    func testStopPreservesWaitingAndBackgroundMetadata() {
        var ledger = SessionLedger()
        ledger.apply(event(.question, at: 1))
        var stop = event(.responseFinished, at: 2); stop.backgroundCount = 2; stop.scheduledCount = 1
        XCTAssertNil(ledger.apply(stop))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .question)
        XCTAssertEqual(ledger.sessions["session-a"]?.backgroundCount, 2)
    }
    func testContinuationAfterStopRestoresWorking() {
        var ledger = SessionLedger()
        XCTAssertEqual(ledger.apply(event(.responseFinished, at: 1)), .completed)
        ledger.apply(event(.toolStarted, at: 2, tool: "Read"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testEndedSessionIgnoresLateAgentActivityUntilResume() {
        var ledger = SessionLedger()
        ledger.apply(event(.sessionEnded, at: 1))
        ledger.apply(event(.toolStarted, at: 2, agent: "child"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .ended)
        ledger.apply(event(.sessionStarted, at: 3))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .idle)
    }
    func testTwoPendingCallsResolveIndependently() {
        var ledger = SessionLedger()
        ledger.apply(event(.permission, at: 1, call: "a", tool: "Bash"))
        ledger.apply(event(.permission, at: 2, call: "b", tool: "Bash"))
        ledger.apply(event(.toolFinished, at: 3, call: "a", tool: "Bash"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .permission)
        XCTAssertEqual(ledger.sessions["session-a"]?.pending.count, 1)
        ledger.apply(event(.toolFinished, at: 4, call: "b", tool: "Bash"))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testIdleReminderNeverInfersCompletion() {
        var ledger = SessionLedger()
        ledger.apply(event(.prompt, at: 1))
        XCTAssertNil(ledger.apply(event(.reminder, at: 90)))
        XCTAssertEqual(ledger.sessions["session-a"]?.state, .running)
    }
    func testFailureAndEndClearPending() {
        var ledger = SessionLedger()
        ledger.apply(event(.plan, at: 1))
        XCTAssertEqual(ledger.apply(event(.failed, at: 2)), .failed)
        XCTAssertTrue(ledger.sessions["session-a"]!.pending.isEmpty)
        ledger.apply(event(.sessionEnded, at: 3))
        XCTAssertTrue(ledger.sortedSessions.isEmpty)
    }
    func testPersistedSnapshotCannotContainQuestionPreview() throws {
        var ledger = SessionLedger()
        var question = event(.question, at: 1); question.preview = "PRIVATE-QUESTION"
        ledger.apply(question)
        let data = try JSONEncoder().encode(ledger.persistentCopy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-QUESTION"))
        let restored = try JSONDecoder().decode(SessionLedger.self, from: data)
        XCTAssertEqual(restored.sessions["session-a"]?.state, .question)
        XCTAssertEqual(restored.sessions["session-a"]?.pending.count, 1)
    }
    func testRetentionKeepsUnresolvedWaitButPrunesOldHistory() {
        var ledger = SessionLedger()
        ledger.apply(event(.question, at: 1))
        ledger.apply(event(.sessionEnded, at: 2, session: "ended"))
        ledger.prune(now: base.addingTimeInterval(10 * 86400), days: 7)
        XCTAssertNotNil(ledger.sessions["session-a"])
        XCTAssertNil(ledger.sessions["ended"])
        XCTAssertTrue(ledger.history.isEmpty)
    }
    func testReplayedMutedSnoozedAndUnverifiedSessionsAreSilent() {
        var session = AgentSession(id: "x", cwd: "/x", lastEvent: base, source: .init()); session.state = .question
        let prefs = Preferences()
        XCTAssertNotEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base), .silent)
        XCTAssertEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: true, now: base), .silent)
        session.revalidated = false
        XCTAssertEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base), .silent)
        session.revalidated = true; session.muted = true
        XCTAssertEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base), .silent)
        session.muted = false; session.snoozedUntil = base.addingTimeInterval(300)
        XCTAssertEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base), .silent)
    }
    func testFocusedSourceTerminalSuppressesAlerts() {
        var session = AgentSession(id: "x", cwd: "/x", lastEvent: base, source: .init()); session.state = .completed
        var prefs = Preferences()
        XCTAssertEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base, sourceFocused: true), .silent)
        XCTAssertNotEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base, sourceFocused: false), .silent)
        prefs.suppressWhenSourceFocused = false
        XCTAssertNotEqual(AttentionEngine.decide(session: session, preferences: prefs, replay: false, now: base, sourceFocused: true), .silent)
    }
    func testQuietHoursCrossMidnightAndSameDay() {
        var prefs = Preferences(); prefs.quietHours = true
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func time(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: hour))! }
        XCTAssertTrue(prefs.isQuiet(at: time(23), calendar: calendar))
        XCTAssertTrue(prefs.isQuiet(at: time(7), calendar: calendar))
        XCTAssertFalse(prefs.isQuiet(at: time(12), calendar: calendar))
        prefs.quietStart = 9 * 60; prefs.quietEnd = 17 * 60
        XCTAssertTrue(prefs.isQuiet(at: time(12), calendar: calendar))
        XCTAssertFalse(prefs.isQuiet(at: time(23), calendar: calendar))
    }
    func testRoutingAlwaysPrefersKnownSourceOverSavedDefault() {
        let cursor = TerminalChoice.cursor.rawValue, warp = TerminalChoice.warp.rawValue
        XCTAssertEqual(RoutingPolicy.decide(source: cursor, running: [warp, cursor], preferred: warp), .activate(cursor))
        XCTAssertEqual(RoutingPolicy.decide(source: cursor, running: [warp], preferred: warp), .sourceClosed)
        XCTAssertEqual(RoutingPolicy.decide(source: nil, running: [warp], preferred: cursor), .activate(warp))
        XCTAssertEqual(RoutingPolicy.decide(source: nil, running: [warp, cursor], preferred: nil), .choose([warp, cursor]))
        XCTAssertEqual(RoutingPolicy.decide(source: nil, running: [], preferred: nil), .noApplications)
    }
}
