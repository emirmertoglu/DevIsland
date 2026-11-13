import AppKit
import DevIslandCore

@MainActor final class TerminalRouter {
    private let model: AppModel
    private let queue = DispatchQueue(label: "dev.island.editor-route", qos: .userInitiated)
    private var generation = 0
    private var installing = false
    init(model: AppModel) {
        self.model = model
        model.installVSCodeConnector = { [weak self] in self?.installConnector() }
    }
    func route(_ session: AgentSession) {
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let id = app.bundleIdentifier, TerminalChoice(rawValue: id) != nil else { return nil }
            return id
        }
        let running = Array(Set(candidates)).sorted()
        switch RoutingPolicy.decide(source: session.source.bundleID, running: running, preferred: model.preferences.preferredTerminal) {
        case .activate(let id): activate(id, session: session)
        case .sourceClosed:
            message(model.t("Kaynak uygulama kapalı", "Source application is closed"),
                    model.t("Bu Claude oturumu başka bir terminale taşınmadı. Kaynak uygulamayı yeniden açıp oturum durumunu kontrol edebilirsin.", "This Claude session has not moved to another terminal. Reopen its source app and check the session."))
        case .noApplications:
            message(model.t("Açık terminal bulunamadı", "No terminal application is running"),
                    model.t("VS Code, Cursor, Warp veya Apple Terminal’i açıp yeniden dene.", "Open VS Code, Cursor, Warp or Apple Terminal and try again."))
        case .choose(let ids):
            let alert = NSAlert()
            alert.messageText = model.t("Hangi uygulamaya dönelim?", "Which application should open?")
            alert.informativeText = model.t("Bu oturumun kaynak uygulaması belirlenemedi. Seçim yalnızca kaynak belirsiz olduğunda kullanılır.", "The source of this session is unknown. Your preference only applies to unknown sources.")
            for id in ids { alert.addButton(withTitle: TerminalChoice(rawValue: id)?.title ?? id) }
            alert.addButton(withTitle: model.t("Vazgeç", "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = model.t("Tercihimi hatırla", "Remember my choice")
            NSApp.activate(ignoringOtherApps: true)
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard ids.indices.contains(index) else { return }
            if alert.suppressionButton?.state == .on { model.preferences.preferredTerminal = ids[index] }
            activate(ids[index], session: session)
        }
    }
    private func activate(_ id: String, session: AgentSession) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        if id == TerminalChoice.vscode.rawValue {
            generation += 1; let ticket = generation
            // Serialize requests so rapid clicks finish on the most recently requested session.
            queue.async { [weak self] in
                let result = Result { try EditorRouteClient.focus(session: session) }
                Task { @MainActor in
                    guard let self, ticket == self.generation else { return }
                    switch result {
                    case .success:
                        self.model.status = self.model.t("VS Code: ilgili pencere ve terminal seçildi.", "VS Code: the matching window and terminal are focused.")
                    case .failure(let error): self.routingFailed(error)
                    }
                }
            }
            return
        }
        app.activate(options: [.activateAllWindows])
        if id == TerminalChoice.terminal.rawValue, let tty = session.source.tty,
           tty.hasPrefix("/dev/"), tty.count < 100, tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." || $0 == "_" || $0 == "-" }) {
            // TTY is validated as data, never interpolated from user commands or transcript text.
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
                return false
            end tell
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error != nil {
                model.status = model.t("Terminal açıldı. Sekme seçimi için Automation izni gerekir; Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon bölümünden açabilirsin.", "Terminal opened. Tab selection requires Automation permission in System Settings > Privacy & Security > Automation.")
            } else if result?.booleanValue != true {
                model.status = model.t("Terminal açıldı; eşleşen sekme artık bulunamıyor.", "Terminal opened; the matching tab is no longer available.")
            }
        }
    }
    private func routingFailed(_ error: Error) {
        if error as? EditorRoutingError == .missingConnector {
            let alert = NSAlert()
            alert.messageText = model.t("VS Code terminal bağlantısı gerekiyor", "VS Code terminal connection required")
            alert.informativeText = model.t("Doğru pencere ve terminali seçmek için uygulamayla gelen Dev Island eklentisini kur. Mevcut terminaller korunur. Kurulumdan sonra bağlanmayan pencerede Developer: Reload Window çalıştırabilirsin.", "Install the bundled Dev Island extension to select the exact window and terminal. Existing terminals are preserved. If a window stays disconnected, run Developer: Reload Window there when convenient.")
            alert.addButton(withTitle: model.t("VS Code bağlantısını kur", "Install VS Code connection"))
            alert.addButton(withTitle: model.t("Vazgeç", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { installConnector() }
            return
        }
        let detail: String
        switch error as? EditorRoutingError {
        case .editorTooOld:
            detail = model.t("Dev Island eklentisi bağlı, ancak bu VS Code sürümü pencere odaklamayı desteklemiyor. VS Code'u güncelle (Code > Check for Updates), ardından pencerelerde Developer: Reload Window çalıştır.", "The Dev Island extension is connected, but this VS Code version cannot focus windows. Update VS Code (Code > Check for Updates), then run Developer: Reload Window in its windows.")
        case .sourceUnavailable:
            detail = model.t("Claude süreci kapandı veya süreç kimliği doğrulanamadı. Oturum başka bir terminalde açılmış gibi yönlendirme yapılmadı.", "The Claude process exited or its identity could not be verified. No replacement terminal was opened.")
        case .ambiguous:
            detail = model.t("Birden fazla terminal eşleşti. Yanlış pencereyi seçmemek için yönlendirme durduruldu; VS Code bağlantısını ilgili pencerelerde yenile.", "More than one terminal matched. Routing stopped to avoid selecting the wrong window; refresh the connection in those VS Code windows.")
        case .missingTerminal:
            detail = model.t("Bu Claude sürecine ait terminal bulunamadı. İlgili pencerede Dev Island bağlantısının etkin olduğundan emin ol. Uzak/tmux oturumlarına tam dönüş bu sürümde desteklenmiyor.", "The terminal owning this Claude process was not found. Check the Dev Island connection in that window. Exact remote/tmux routing is not supported in this version.")
        default:
            detail = model.t("VS Code pencere/terminal seçimini doğrulayamadı. Terminal kapanmış veya eklenti bağlantısı kesilmiş olabilir. İlgili pencerede Dev Island: Show Terminal Connection Status komutunu kontrol et.", "VS Code could not confirm the window/terminal focus. The terminal may have closed or the extension disconnected. Check Dev Island: Show Terminal Connection Status in that window.")
        }
        model.status = detail
        message(model.t("İlgili terminale dönülemedi", "Could not return to the matching terminal"), detail)
    }
    func installConnector() {
        guard !installing else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalChoice.vscode.rawValue) else {
            message(model.t("VS Code bulunamadı", "VS Code not found"), model.t("Önce masaüstü VS Code uygulamasını kur.", "Install desktop VS Code first.")); return
        }
        let cli = app.appendingPathComponent("Contents/Resources/app/bin/code")
        let vsix = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/DevIslandVSCode.vsix")
        guard FileManager.default.fileExists(atPath: vsix.path) else {
            message(model.t("Bağlantı paketi eksik", "Connection package is missing"), model.t("Paketlenmiş Dev Island.app kopyasını kullan.", "Use the packaged Dev Island.app.")); return
        }
        installing = true; model.status = model.t("VS Code bağlantısı kuruluyor…", "Installing VS Code connection…")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [cli.path, "--install-extension", vsix.path, "--force"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }; self.installing = false
                self.model.status = process.terminationStatus == 0
                    ? self.model.t("VS Code bağlantısı kuruldu. Bağlanmayan açık pencerede uygun olduğunda Developer: Reload Window çalıştır.", "VS Code connection installed. If an open window stays disconnected, run Developer: Reload Window when convenient.")
                    : self.model.t("VS Code bağlantısı kurulamadı. Paket içindeki VSIX dosyasını Extensions > Install from VSIX ile kurabilirsin.", "VS Code connection installation failed. Install the bundled VSIX using Extensions > Install from VSIX.")
            }
        }
        do { try process.run() }
        catch { installing = false; model.status = error.localizedDescription; return }
        Task { try? await Task.sleep(nanoseconds: 45_000_000_000); if process.isRunning { process.terminate() } }
    }
    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: model.t("Tamam", "OK")); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
