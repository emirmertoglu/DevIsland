import AppKit
import Combine
import UserNotifications
import AVFoundation
import DevIslandCore
import CDevIsland

@MainActor final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var ledger = SessionLedger() { didSet { refreshCompanion() } }
    @Published var companion = CompanionActivity()
    @Published var celebrationStarted: Date?
    @Published var visualsAwake = true
    @Published var mascotTrayVisible = false
    @Published var settingsVisible = false
    @Published var preferences = Preferences() {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
            refreshCompanion()
            settingsChanged?()
        }
    }
    @Published var status = ""
    @Published var notificationStatus = ""
    @Published var integrationInstalled = false
    @Published var integrationBlocked = false
    @Published var claudeVersion = ""
    @Published var lastReceived: Date?
    @Published var startupError: String?
    @Published var configPath: String {
        didSet { defaults.set(configPath, forKey: "claudeConfigPath"); refreshIntegration() }
    }
    lazy var updates = UpdateController(defaults: defaults)
    let paths: AppPaths
    let defaults: UserDefaults
    var repository: SessionRepository?
    var settingsChanged: (() -> Void)?
    var showSettings: (() -> Void)?
    var showSessions: (() -> Void)?
    var presentAlert: ((String) -> Void)?
    var installVSCodeConnector: (() -> Void)?
    var routeSession: ((AgentSession) -> Void)?
    var resetMascotPosition: (() -> Void)?
    var resetIslandPosition: (() -> Void)?
    private var celebratingSessionID: String?
    private var celebrationGate = CelebrationGate()
    private var celebrationTask: Task<Void, Never>?
    private var nameRefresh: Task<Void, Never>?
    private var socketSource: DispatchSourceRead?
    private var timer: Timer?
    private var soundPlayer: AVAudioPlayer?
    private var maintenanceTick = 0
    private var socketFD: Int32 = -1
    private var burstSounds: Date = .distantPast
    private var pendingCompletion: [String: Task<Void, Never>] = [:]
    var installer: HookInstaller { HookInstaller(configDirectory: URL(fileURLWithPath: configPath), paths: paths) }
    var sessions: [AgentSession] { ledger.sortedSessions }
    var waitingCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var runningCount: Int { sessions.filter { $0.state == .running }.count }
    var isTurkish: Bool {
        preferences.language == "tr" || (preferences.language == "system" && Locale.preferredLanguages.first?.hasPrefix("tr") == true)
    }
    func t(_ tr: String, _ en: String) -> String { isTurkish ? tr : en }
    func title(_ state: SessionState) -> String {
        switch state {
        case .idle: return t("Hazır", "Ready")
        case .running: return t("Çalışıyor", "Working")
        case .question: return t("Soru bekliyor", "Needs your answer")
        case .plan: return t("Plan onayı bekliyor", "Plan ready for approval")
        case .permission: return t("İzin bekliyor", "Needs permission")
        case .completed: return t("Yanıt tamamlandı", "Response finished")
        case .failed: return t("Tur hatayla durdu", "Turn stopped with an error")
        case .disconnected: return t("Bağlantı kesildi", "Disconnected")
        case .ended: return t("Oturum kapandı", "Session ended")
        }
    }
    override convenience init() {
        let args = CommandLine.arguments
        let paths: AppPaths
        if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1) {
            paths = AppPaths(root: URL(fileURLWithPath: args[index + 1]))
        } else { paths = AppPaths() }
        let defaults = UserDefaults(suiteName: args.contains("--demo") || args.contains("--render-preview") ? "dev.island.demo" : "dev.island.app") ?? .standard
        self.init(paths: paths, defaults: defaults)
    }
    init(paths: AppPaths, defaults: UserDefaults, loadPersistentState: Bool = true) {
        self.paths = paths; self.defaults = defaults
        configPath = defaults.string(forKey: "claudeConfigPath") ?? HookInstaller().configDirectory.path
        super.init()
        if let data = defaults.data(forKey: "preferences.v1"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        guard loadPersistentState else { return }
        do {
            try paths.prepare()
            repository = try SessionRepository(root: paths.root)
            ledger = try repository!.load()
            for id in ledger.sessions.keys { ledger.sessions[id]?.revalidated = false }
            ledger.prune(days: preferences.retentionDays)
        } catch { startupError = error.localizedDescription }
    }
    func start() {
        UNUserNotificationCenter.current().delegate = self
        socketFD = di_socket_listen(paths.socket)
        if socketFD >= 0 {
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
            source.setEventHandler { [weak self] in self?.receiveSocket() }
            source.setCancelHandler { [socketFD] in close(socketFD) }
            source.resume(); socketSource = source
        } else { status = t("Canlı bağlantı açılamadı; dosya kuyruğu etkin.", "Live connection unavailable; file queue is active.") }
        drainQueue(replay: true)
        validateProcesses(); refreshSessionNames()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        if Bundle.main.infoDictionary?["DevIslandOfficialRelease"] as? Bool == true {
            do { try installer.refreshInstalledHelper(from: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dev-island-bridge")) }
            catch { status = t("Köprü yenilenemedi: ", "Could not refresh bridge: ") + error.localizedDescription }
        }
        refreshIntegration(); refreshNotificationPermission(); detectClaudeVersion()
        if CommandLine.arguments.contains("--demo") { seedDemo() }
    }
    func stop() {
        nameRefresh?.cancel(); nameRefresh = nil
        celebrationTask?.cancel()
        for task in pendingCompletion.values { task.cancel() }
        timer?.invalidate(); socketSource?.cancel()
        if socketFD >= 0 { unlink(paths.socket) }
        try? repository?.save(ledger)
    }
    @objc private func woke() { visualsAwake = true; drainQueue(replay: true); validateProcesses(); refreshSessionNames() }
    @objc private func sleeping() {
        visualsAwake = false; celebrationTask?.cancel(); celebratingSessionID = nil; celebrationStarted = nil; refreshCompanion()
        for task in pendingCompletion.values { task.cancel() }; pendingCompletion.removeAll()
    }
    func refreshCompanion() {
        let next = CompanionResolver.resolve(sessions: ledger.sortedSessions, seen: preferences.seenCompletions, celebrating: celebratingSessionID)
        if companion != next { companion = next }
    }
    func refreshSessionNames() {
        guard nameRefresh == nil else { return }
        let snapshot = sessions, directory = URL(fileURLWithPath: configPath)
        nameRefresh = Task { [weak self] in
            let names = await Task.detached(priority: .utility) {
                ClaudeSessionNames.lookup(sessions: snapshot, configDirectory: directory)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard URL(fileURLWithPath: self.configPath).standardizedFileURL == directory.standardizedFileURL else { self.nameRefresh = nil; return }
            self.applySessionNames(names, baseline: snapshot)
            self.nameRefresh = nil
        }
    }
    func applySessionNames(_ names: [String: ClaudeSessionName], baseline: [AgentSession]? = nil) {
        var updated = ledger, changed = false
        for (id, name) in names {
            guard let session = updated.sessions[id], session.isActive,
                  session.sessionName != name,
                  session.sessionName?.origin != .custom || name.origin == .custom else { continue }
            // A newer hook/rename may have arrived while the background read was running.
            if let baseline, baseline.first(where: { $0.id == id })?.sessionName != session.sessionName { continue }
            updated.sessions[id]?.sessionName = name; changed = true
        }
        if changed { ledger = updated; try? repository?.save(ledger) }
    }
    func showDesktopMascot(resetPosition: Bool = false) {
        var updated = preferences
        updated.showDesktopMascot(resetPosition: resetPosition)
        preferences = updated
    }
    func sessionPresentation(for session: AgentSession) -> SessionPresentation {
        SessionPresentation(session: session, hideProjects: preferences.hideProjects,
                            celebrating: celebratingSessionID, celebrationStarted: celebrationStarted)
    }
    func islandSession(alertSessionID: String? = nil) -> AgentSession? {
        if let id = alertSessionID, let session = ledger.sessions[id], session.isActive { return session }
        return companion.sessionID.flatMap { ledger.sessions[$0] }
    }
    func markCompletionsSeen() {
        var seen = preferences.seenCompletions
        for session in sessions where session.state == .completed { seen[session.id] = session.lastEvent }
        seen = seen.filter { ledger.sessions[$0.key] != nil }
        if seen != preferences.seenCompletions { preferences.seenCompletions = seen }
    }
    private func celebrate(_ id: String, eventID: UUID, replay: Bool) {
        guard let session = ledger.sessions[id],
              celebrationGate.allow(eventID: eventID, session: session, preferences: preferences, replay: replay, awake: visualsAwake) else { return }
        celebrationTask?.cancel(); celebratingSessionID = id; celebrationStarted = Date(); refreshCompanion()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.celebratingSessionID = nil; self.celebrationStarted = nil; self.refreshCompanion()
        }
    }
    private func receiveSocket() {
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            let count = di_socket_receive(socketFD, &buffer, buffer.count)
            if count <= 0 { break }
            if let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(buffer.prefix(Int(count)))) {
                handle(event, replay: Date().timeIntervalSince(event.timestamp) > 10)
            }
        }
    }
    private func drainQueue(replay: Bool) {
        guard let files = try? EventQueue.pending(paths: paths) else { return }
        let events = files.compactMap { url -> AgentEvent? in
            do { return try EventQueue.read(url) }
            catch { try? FileManager.default.removeItem(at: url); return nil }
        }.sorted { $0.timestamp < $1.timestamp }
        for event in events { handle(event, replay: replay || Date().timeIntervalSince(event.timestamp) > 10) }
    }
    func handle(_ event: AgentEvent, replay: Bool = false) {
        guard event.version == 1, event.timestamp <= Date().addingTimeInterval(60) else { return }
        let previous = ledger.sessions[event.sessionID]
        let transition = ledger.apply(event)
        // A datagram may follow a queue sweep: ephemeral preview can still arrive without a second alert.
        if event.kind == .question, let preview = event.preview, ledger.sessions[event.sessionID]?.state == .question,
           event.timestamp >= (previous?.lastEvent ?? .distantPast) { ledger.sessions[event.sessionID]?.preview = preview }
        lastReceived = Date()
        ledger.prune(days: preferences.retentionDays)
        do {
            guard let repository else { return }
            try repository.save(ledger)
            EventQueue.acknowledge(event, paths: paths)
        } catch { status = t("Olay kaydedilemedi: ", "Could not save event: ") + error.localizedDescription; return }
        if ledger.sessions[event.sessionID]?.state != .completed {
            pendingCompletion[event.sessionID]?.cancel(); pendingCompletion.removeValue(forKey: event.sessionID)
        }
        if let transition {
            if transition == .completed {
                pendingCompletion[event.sessionID]?.cancel()
                pendingCompletion[event.sessionID] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled, let self, self.ledger.sessions[event.sessionID]?.state == .completed else { return }
                    self.celebrate(event.sessionID, eventID: event.id, replay: replay)
                    self.alert(sessionID: event.sessionID, replay: replay)
                    self.pendingCompletion.removeValue(forKey: event.sessionID)
                }
            } else { alert(sessionID: event.sessionID, replay: replay) }
        }
        if let old = previous, old.state.needsAttention, ledger.sessions[event.sessionID]?.state.needsAttention == false {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [event.sessionID])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [event.sessionID])
        }
    }
    private func tick() {
        maintenanceTick += 1
        if maintenanceTick % 2 == 0 { drainQueue(replay: false) }
        if maintenanceTick % 5 == 0 { refreshSessionNames() }
        if maintenanceTick % 15 == 0 { validateProcesses() }
        if maintenanceTick % 60 == 0 { ledger.prune(days: preferences.retentionDays); try? repository?.save(ledger) }
        for session in sessions {
            if let until = session.snoozedUntil, until <= Date() {
                ledger.sessions[session.id]?.snoozedUntil = nil
                ledger.sessions[session.id]?.reminderSent = true
                if session.state.needsAttention { alert(sessionID: session.id, replay: false) }
                try? repository?.save(ledger)
            }
        }
        if preferences.reminders {
            for s in sessions where s.state.isWaiting && !s.reminderSent {
                if let since = s.attentionSince, Date().timeIntervalSince(since) >= 120,
                   AttentionEngine.decide(session: s, preferences: preferences, replay: false, sourceFocused: isSourceFocused(s)) != .silent {
                    ledger.sessions[s.id]?.reminderSent = true
                    alert(sessionID: s.id, replay: false)
                    try? repository?.save(ledger)
                }
            }
        }
    }
    private func validateProcesses() {
        var changed = false
        for s in sessions {
            guard let pid = s.source.processID, let start = s.source.processStart else { continue }
            let alive = ProcessIdentity.isAlive(pid: pid, start: start)
            if alive == false, s.state != .disconnected {
                ledger.sessions[s.id]?.state = .disconnected
                ledger.sessions[s.id]?.preview = nil
                ledger.sessions[s.id]?.revalidated = false
                changed = true
            } else if alive == true, !s.revalidated {
                ledger.sessions[s.id]?.revalidated = true; changed = true
            }
        }
        if changed { try? repository?.save(ledger) }
    }
    private func alert(sessionID: String, replay: Bool) {
        guard let session = ledger.sessions[sessionID] else { return }
        let decision = AttentionEngine.decide(session: session, preferences: preferences, replay: replay, sourceFocused: isSourceFocused(session))
        if decision.island { presentAlert?(sessionID) }
        let systemSound = preferences.soundMode == "system"
        // System mode always uses a native delivery, preserving Focus behavior and avoiding custom playback.
        if decision.notification || (decision.sound && systemSound) {
            let content = UNMutableNotificationContent()
            content.title = "Dev Island"
            content.body = title(session.state)
            content.userInfo = ["sessionID": sessionID]
            content.threadIdentifier = sessionID
            if decision.sound && systemSound { content.sound = .default }
            let request = UNNotificationRequest(identifier: sessionID, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error { Task { @MainActor in self?.status = error.localizedDescription } }
            }
        }
        if decision.sound && !systemSound && Date().timeIntervalSince(burstSounds) > 0.7 {
            burstSounds = Date(); playSound()
        }
    }
    /// Exact terminal check: VS Code is frontmost and its focused window's active terminal hosts this session.
    private func isSourceFocused(_ session: AgentSession) -> Bool {
        guard preferences.suppressWhenSourceFocused, session.source.bundleID == TerminalChoice.vscode.rawValue,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalChoice.vscode.rawValue else { return false }
        return EditorRouteClient.isFocused(session: session)
    }
    func playSound() {
        if preferences.soundMode == "system" { NSSound.beep(); return }
        let url = preferences.soundMode == "file" ? URL(fileURLWithPath: preferences.customSoundPath)
            : URL(fileURLWithPath: "/System/Library/Sounds/\(preferences.soundName).aiff")
        do {
            soundPlayer = try AVAudioPlayer(contentsOf: url)
            soundPlayer?.volume = Float(max(0, min(1, preferences.volume)))
            soundPlayer?.play()
        } catch { status = t("Ses açılamadı: ", "Could not open sound: ") + error.localizedDescription }
    }
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
            Task { @MainActor in if let error { self?.status = error.localizedDescription }; self?.refreshNotificationPermission() }
        }
    }
    func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.notificationStatus = self.t("İzin verildi", "Allowed")
                case .denied: self.notificationStatus = self.t("İzin kapalı — Sistem Ayarları’ndan açabilirsin", "Denied — enable in System Settings")
                default: self.notificationStatus = self.t("Henüz istenmedi", "Not requested")
                }
            }
        }
    }
    func refreshIntegration() {
        do {
            let result = try installer.inspect()
            integrationInstalled = result.installed; integrationBlocked = result.blocked
        } catch { status = error.localizedDescription; integrationInstalled = false; integrationBlocked = false }
    }
    func installIntegration() {
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dev-island-bridge")
            try installer.install(helper: helper)
            defaults.set(true, forKey: "onboarded")
            status = t("Bağlandı. Açık Claude oturumlarını yeniden başlat; ayarların yedeği alındı.", "Connected. Restart existing Claude sessions; settings were backed up.")
        } catch { status = error.localizedDescription }
        refreshIntegration()
    }
    func uninstallIntegration() {
        do { try installer.uninstall(); status = t("Yalnızca Dev Island hook’ları kaldırıldı.", "Only Dev Island hooks were removed.") }
        catch { status = error.localizedDescription }
        refreshIntegration()
    }
    func testBridge() {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dev-island-bridge")
        process.arguments = ["--claude-hook"]
        var env = ProcessInfo.processInfo.environment; env["DEV_ISLAND_HOME"] = paths.root.path; process.environment = env
        let input = Pipe(); process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let payload: [String: Any] = ["session_id": "diagnostic-" + UUID().uuidString, "cwd": "/Dev Island Test", "hook_event_name": "PreToolUse",
                                      "tool_name": "AskUserQuestion", "tool_use_id": "diagnostic-question",
                                      "tool_input": ["questions": [["question": t("Bağlantı testi başarılı. Bu örnek oturumu kapatabilirsin.", "Bridge test received. You can dismiss this sample session.")]]]]
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            status = t("Köprüye test olayı gönderildi; oturum listesinde görünmesini kontrol et.", "Sent a bridge test; check for a sample session in the list.")
        } catch { status = error.localizedDescription }
    }
    func mutateSession(_ id: String, _ edit: (inout AgentSession) -> Void) {
        guard var session = ledger.sessions[id] else { return }
        edit(&session); ledger.sessions[id] = session
        try? repository?.save(ledger)
    }
    func clearHistory() { ledger.history.removeAll(); ledger.sessions = ledger.sessions.filter { $0.value.isActive }; try? repository?.save(ledger) }
    func openNotificationSettings() { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } }
    private func detectClaudeVersion() {
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            claudeVersion = t("Claude bulunamadı; yapılandırma dizinini kontrol et.", "Claude not found; check your configuration directory."); return
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--version"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global().async { [weak self] in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor in self?.claudeVersion = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? path }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        } catch { claudeVersion = error.localizedDescription }
    }
    private func seedDemo() {
        let examples: [(String, String, EventKind)] = [("demo-cookify", "/Projects/Cookify", .question), ("demo-nailoria", "/Projects/Nailoria", .plan), ("demo-landing", "/Projects/Landing", .toolStarted)]
        for (id, cwd, kind) in examples {
            handle(AgentEvent(sessionID: id, kind: kind, cwd: cwd, toolCallID: id, toolName: kind == .question ? "AskUserQuestion" : nil,
                source: .init(bundleID: TerminalChoice.cursor.rawValue), preview: kind == .question ? t("Hangi giriş yöntemini kullanmak istersin?", "Which sign-in method would you like to use?") : nil), replay: true)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in if let id, let session = self.ledger.sessions[id] { self.routeSession?(session) } else { self.showSessions?() } }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
