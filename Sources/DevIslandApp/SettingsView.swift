import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import DevIslandCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, notifications, appearance, integration, privacy, history, updates
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.stack.3d.up"
        case .notifications: return "bell.badge"
        case .appearance: return "rectangle.topthird.inset.filled"
        case .integration: return "point.3.connected.trianglepath.dotted"
        case .privacy: return "hand.raised"
        case .history: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        }
    }
    @MainActor func title(_ m: AppModel) -> String {
        switch self {
        case .overview: return m.t("Genel bakış", "Overview")
        case .notifications: return m.t("Bildirimler ve ses", "Alerts & sound")
        case .appearance: return m.t("Görünüm", "Appearance")
        case .integration: return m.t("Claude bağlantısı", "Claude connection")
        case .privacy: return m.t("Gizlilik ve genel", "Privacy & general")
        case .history: return m.t("Olay geçmişi", "Activity history")
        case .updates: return m.t("Güncellemeler", "Updates")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    private var colors: ThemeColors { model.preferences.themeColors(systemScheme: systemScheme) }
    @State private var page: SettingsPage = .overview
    @State private var showHookPreview = false
    @State private var confirmingClear = false
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    init(model: AppModel, initialPage: SettingsPage = .overview) {
        self.model = model; _page = State(initialValue: initialPage)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    DevIslandMark(size: 24)
                    Text("Dev Island").font(.system(size: 14, weight: .semibold))
                }.padding(.horizontal, 16).padding(.top, 20)
                List(selection: Binding<SettingsPage?>(get: { page }, set: { if let value = $0 { page = value } })) {
                    ForEach(SettingsPage.allCases) { item in
                        Label(item.title(model), systemImage: item.icon).font(.system(size: 13)).tag(item)
                    }
                }.listStyle(.sidebar)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle().fill(model.integrationInstalled && !model.integrationBlocked ? SessionState.completed.tint : islandOrange).frame(width: 5, height: 5)
                    Text(model.integrationInstalled ? model.t("Bağlı", "Connected") : model.t("Bağlı değil", "Not connected"))
                    Spacer()
                    Text(BuildInfo.version)
                }.font(.system(size: 10)).foregroundStyle(Color(colors.secondary)).padding(16)
            }.frame(width: 216).background(Color(colors.canvas))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(page.title(model)).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if page == .overview {
                        Button { model.showSessions?() } label: { Label(model.t("Adayı aç", "Open island"), systemImage: "rectangle.topthird.inset.filled") }
                            .font(.system(size: 11)).help(model.t("Oturum panelini aç", "Open activity panel"))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 18)
                Divider()
                SnapshotScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = model.startupError { notice(model.t("Veri deposu açılamadı: ", "Storage could not open: ") + error, symbol: "exclamationmark.triangle") }
                        switch page {
                        case .overview: overview
                        case .notifications: notifications
                        case .appearance: appearance
                        case .integration: integration
                        case .privacy: privacy
                        case .history: history
                        case .updates: UpdatesSettingsView(updates: model.updates, model: model)
                        }
                    }.padding(20)
                }
                if !model.status.isEmpty {
                    Divider()
                    Text(model.status).font(.system(size: 11)).foregroundStyle(Color(colors.secondary)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(colors.content))
        }
        .frame(minWidth: 780, minHeight: 580)
        .appTheme(model.preferences)
        .sheet(isPresented: $showHookPreview) {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.t("Eklenecek Claude hook’ları", "Claude hooks to add")).font(.title2)
                Text(model.t("Mevcut ayarlar korunur. Kurulum öncesinde settings.json yedeklenir.", "Existing settings are preserved. settings.json is backed up before installation.")).font(.callout).foregroundStyle(Color(colors.secondary))
                ScrollView { Text(model.installer.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(model.t("Vazgeç", "Cancel")) { showHookPreview = false }
                    Spacer()
                    Button(model.t("Bağlantıyı kur", "Install connection")) { model.installIntegration(); showHookPreview = false }.buttonStyle(AccentButtonStyle())
                }
            }.padding(24).frame(width: 600, height: 520).appTheme(model.preferences)
        }
        .alert(model.t("Geçmiş silinsin mi?", "Clear activity history?"), isPresented: $confirmingClear) {
            Button(model.t("Sil", "Clear"), role: .destructive) { model.clearHistory() }
            Button(model.t("Vazgeç", "Cancel"), role: .cancel) {}
        } message: { Text(model.t("Aktif ve bekleyen oturumlar korunur.", "Active and waiting sessions are kept.")) }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginEnabled = SMAppService.mainApp.status == .enabled
            model.refreshNotificationPermission(); model.refreshIntegration()
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Label(model.t("\(model.waitingCount) bekleyen", "\(model.waitingCount) waiting"), systemImage: "bell.badge")
                    .foregroundStyle(Color(colors.accent))
                Text("·").foregroundStyle(Color(colors.secondary))
                Text(model.t("\(model.runningCount) çalışan", "\(model.runningCount) working")).foregroundStyle(Color(colors.secondary))
                Spacer()
                Text(model.t("\(model.sessions.count) oturum", "\(model.sessions.count) sessions")).foregroundStyle(Color(colors.secondary))
            }.font(.system(size: 12))
            if !model.integrationInstalled {
                group {
                    Label(model.t("Claude bağlantısı kurulmadı", "Claude is not connected"), systemImage: "link").font(.system(size: 13, weight: .medium))
                    Text(model.t("Oturumları izlemek için yerel hook bağlantısını kur.", "Install local hooks to follow your sessions.")).font(.system(size: 12)).foregroundStyle(Color(colors.secondary))
                    HStack {
                        Button(model.t("Hook’ları incele ve bağlan", "Review hooks & connect")) { showHookPreview = true }
                        Button(model.t("Önizleme", "Preview")) { model.testBridge(); model.showSessions?() }
                    }
                }
            }
            VStack(spacing: 0) {
                if model.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 24)).foregroundStyle(Color(colors.secondary))
                        Text(model.t("Aktif oturum yok", "No active sessions")).font(.system(size: 13, weight: .medium))
                        Text(model.t("Claude’a bir prompt gönderdiğinde burada görünür.", "Send Claude a prompt to see a session here.")).font(.system(size: 12)).foregroundStyle(Color(colors.secondary))
                    }.frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    ForEach(model.sessions) { session in
                        SessionRow(model: model, session: session)
                        if session.id != model.sessions.last?.id { Divider().padding(.leading, 40) }
                    }
                }
            }
            Divider()
            Label(model.t("Yalnızca oturum metaverisi bu Mac’te saklanır.", "Only session metadata is stored on this Mac."), systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(Color(colors.secondary))
        }
    }
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 18) {
            group {
                Toggle(model.t("Sessiz mod", "Quiet mode"), isOn: $model.preferences.quiet)
                Toggle(model.t("2 dakika sonra tek hatırlatma", "One reminder after 2 minutes"), isOn: $model.preferences.reminders)
                Toggle(model.t("Sessiz saatler", "Quiet hours"), isOn: $model.preferences.quietHours)
                if model.preferences.quietHours {
                    HStack {
                        timePicker(model.t("Başlangıç", "From"), value: $model.preferences.quietStart)
                        timePicker(model.t("Bitiş", "Until"), value: $model.preferences.quietEnd)
                    }
                }
            }
            sectionLabel(model.t("DENGELİ PROFİL", "BALANCED PROFILE"))
            group {
                HStack {
                    Text(model.t("Olay", "Event")).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([model.t("Ada", "Island"), model.t("Bildirim", "Banner"), model.t("Ses", "Sound")], id: \.self) { Text($0).frame(width: 60) }
                }.font(.system(size: 10)).foregroundStyle(Color(colors.secondary))
                ForEach([SessionState.question, .plan, .permission, .completed, .failed], id: \.self) { state in
                    HStack {
                        Text(model.title(state)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("", isOn: ruleBinding(state, \.island)).labelsHidden().frame(width: 60).accessibilityLabel(model.title(state) + " " + model.t("ada", "island"))
                        Toggle("", isOn: ruleBinding(state, \.notification)).labelsHidden().frame(width: 60).accessibilityLabel(model.title(state) + " " + model.t("bildirim", "notification"))
                        Toggle("", isOn: ruleBinding(state, \.sound)).labelsHidden().frame(width: 60).accessibilityLabel(model.title(state) + " " + model.t("ses", "sound"))
                    }
                }
            }
            group {
                Picker(model.t("Ses modu", "Sound mode"), selection: $model.preferences.soundMode) {
                    Text(model.t("macOS bildirim sesi", "macOS notification sound")).tag("system")
                    Text(model.t("Hazır ses", "Built-in sound")).tag("preset")
                    Text(model.t("Özel ses dosyası", "Custom sound file")).tag("file")
                }
                if model.preferences.soundMode == "preset" {
                    Picker(model.t("Ses", "Sound"), selection: $model.preferences.soundName) {
                        ForEach(["Glass", "Pop", "Ping", "Tink", "Purr", "Submarine"], id: \.self) { Text($0).tag($0) }
                    }
                }
                if model.preferences.soundMode == "file" {
                    HStack {
                        Text(URL(fileURLWithPath: model.preferences.customSoundPath).lastPathComponent).font(.caption).lineLimit(1)
                        Spacer()
                        Button(model.t("Dosya seç…", "Choose file…")) { chooseSound() }
                    }
                }
                if model.preferences.soundMode != "system" {
                    HStack {
                        Image(systemName: "speaker.wave.1")
                        Slider(value: $model.preferences.volume, in: 0...1).accessibilityLabel(model.t("Uygulama ses düzeyi", "App sound volume"))
                        Text("\(Int(model.preferences.volume * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                HStack {
                    Button(model.t("Sesi dinle", "Preview sound")) { model.playSound() }
                    Spacer()
                    Button(model.t("Dengeli profile dön", "Reset alert profile")) { model.preferences.rules = Preferences().rules }
                }
                Text(model.t("Sistem sesi macOS ses düzeyini ve Focus kurallarını kullanır; ses için sistem bildirimi gerekir. Özel sesler ve ada Focus’tan bağımsızdır: sessiz modu veya sessiz saatleri kullanabilirsin.", "System sound uses macOS volume and Focus rules; sound requires a native notification. Custom sounds and the island operate independently of Focus: use quiet mode or quiet hours."))
                    .font(.system(size: 10)).foregroundStyle(Color(colors.secondary))
            }
            group {
                Text(model.t("Sistem bildirimi: ", "System notifications: ") + model.notificationStatus).font(.caption)
                HStack {
                    Button(model.t("Bildirim izni iste", "Allow notifications")) { model.requestNotifications() }
                    Button(model.t("Sistem Ayarları", "System Settings")) { model.openNotificationSettings() }
                }
            }
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel(model.t("TEMA VE YÜZEY", "THEME & MATERIAL"))
            group {
                Picker(model.t("Tema", "Theme"), selection: $model.preferences.theme) {
                    Text(model.t("Sistem", "System")).tag(ThemeMode.system)
                    Text(model.t("Açık", "Light")).tag(ThemeMode.light)
                    Text(model.t("Koyu", "Dark")).tag(ThemeMode.dark)
                    Text(model.t("Siyah", "Black")).tag(ThemeMode.black)
                }.pickerStyle(.segmented)
                Picker(model.t("Yüzey", "Material"), selection: $model.preferences.surface) {
                    Text("Liquid Glass").tag(SurfaceMaterial.liquid)
                    Text(model.t("Buzlu cam", "Frosted glass")).tag(SurfaceMaterial.frosted)
                    Text(model.t("Opak", "Opaque")).tag(SurfaceMaterial.opaque)
                }
                if model.preferences.surface == .liquid {
                    Picker(model.t("Cam stili", "Glass style"), selection: $model.preferences.glassStyle) {
                        Text(model.t("Standart", "Regular")).tag(GlassStyle.regular)
                        Text(model.t("Berrak", "Clear")).tag(GlassStyle.clear)
                    }
                    Text(model.t("macOS 26’da gerçek Liquid Glass kullanılır. Önceki sürümlerde tercihin korunarak buzlu cam gösterilir.", "Uses native Liquid Glass on macOS 26. Older systems display frosted glass while keeping your preference."))
                        .font(.caption).foregroundStyle(Color(colors.secondary))
                }
                if model.preferences.surface != .opaque {
                    HStack {
                        Text(model.t("Zemin yoğunluğu", "Surface density")).font(.callout)
                        Slider(value: $model.preferences.surfaceDensity, in: 0...1).accessibilityLabel(model.t("Zemin yoğunluğu", "Surface density"))
                    }
                }
                HStack {
                    ColorPicker(model.t("Vurgu rengi", "Accent color"), selection: Binding(get: { Color(hex: model.preferences.accentHex) }, set: { model.preferences.accentHex = $0.hexString }), supportsOpacity: false)
                    Spacer()
                    Button(model.t("Varsayılana sıfırla", "Reset to default")) { model.preferences.resetAccent() }
                        .controlSize(.small).disabled(model.preferences.accentHex.uppercased() == "D97757")
                        .help(model.t("Vurgu rengini #D97757 turuncuya döndür", "Reset accent to #D97757 orange"))
                        .accessibilityLabel(model.t("Vurgu rengini varsayılana sıfırla", "Reset accent color to default"))
                }
                Text(model.t("Tema ve cam seçimi birbirinden bağımsızdır. Şeffaflığı Azalt etkinse yüzeyler opaklaşır.", "Theme and material are independent. Reduce Transparency uses opaque surfaces."))
                    .font(.caption).foregroundStyle(Color(colors.secondary))
            }
            sectionLabel(model.t("ADA VE MASKOT", "ISLAND & MASCOT"))
            group {
                HStack(spacing: 12) {
                    CompanionView(model: model, size: 48, active: model.settingsVisible)
                    Picker(model.t("Karakter", "Character"), selection: $model.preferences.mascot) {
                        Text("Clawd").tag(MascotKind.clawd)
                        Text(model.t("Kedi", "Cat")).tag(MascotKind.cat)
                        Text("Robot").tag(MascotKind.robot)
                    }.pickerStyle(.segmented)
                }
                HStack {
                Picker(model.t("Maskot rengi", "Mascot color"), selection: Binding(get: { model.preferences.selectedMascotColor.mode }, set: { mode in
                    var color = model.preferences.selectedMascotColor; color.mode = mode
                    model.preferences.mascotColors[model.preferences.mascot.rawValue] = color
                })) {
                    Text(model.t("Uygulama rengini izle", "Follow app accent")).tag(MascotColorMode.accent)
                    Text(model.t("Özel renk", "Custom color")).tag(MascotColorMode.custom)
                }
                    Spacer()
                    if model.preferences.selectedMascotColor.mode == .accent { resetMascotColorButton }
                }
                if model.preferences.selectedMascotColor.mode == .custom {
                    HStack {
                    ColorPicker(model.t("Karakter rengi", "Character color"), selection: Binding(get: { Color(hex: model.preferences.selectedMascotColor.hex) }, set: { value in
                        var color = model.preferences.selectedMascotColor; color.hex = value.hexString
                        model.preferences.mascotColors[model.preferences.mascot.rawValue] = color
                    }), supportsOpacity: false)
                    Spacer()
                    resetMascotColorButton
                    }
                }
                Picker(model.t("Gösterim", "Show"), selection: $model.preferences.companionVisibility) {
                    Text(model.t("Ada + maskot", "Island + mascot")).tag(CompanionVisibility.both)
                    Text(model.t("Yalnızca ada", "Island only")).tag(CompanionVisibility.island)
                    Text(model.t("Yalnızca maskot", "Mascot only")).tag(CompanionVisibility.mascot)
                }
                if model.preferences.companionVisibility != .island {
                    Toggle(model.t("Masaüstü maskotunu göster", "Show desktop mascot"), isOn: Binding(get: { !model.preferences.mascotHidden }, set: { model.preferences.mascotHidden = !$0 }))
                    HStack {
                        Text(model.t("Maskot boyutu", "Mascot size")).font(.callout)
                        Slider(value: $model.preferences.mascotSize, in: 64...160, step: 8).accessibilityLabel(model.t("Maskot boyutu", "Mascot size"))
                        Text("\(Int(model.preferences.mascotSize)) pt").monospacedDigit().font(.caption).frame(width: 48)
                    }
                }
                Button(model.t("Maskotu göster ve konumunu sıfırla", "Show mascot and reset its position")) { model.showDesktopMascot(resetPosition: true) }
                    .help(model.t("Maskotu görünür ekran alanına getirir; renk ve boyut korunur.", "Bring the mascot into the visible screen area; color and size are preserved."))
                if !model.preferences.showsMascot {
                    Text(model.t("Masaüstü maskotu gizli. Yukarıdaki düğmeyle geri getirebilirsin.", "The desktop mascot is hidden. Use the button above to bring it back."))
                        .font(.caption).foregroundStyle(Color(colors.secondary))
                }
                Button(model.t("Oturum panelini aç", "Open activity panel")) { model.showSessions?() }
            }
            group {
                Picker(model.t("Ada ekranı", "Island display"), selection: Binding(get: { model.preferences.displayID }, set: { id in
                    var prefs = model.preferences; prefs.displayID = id; prefs.islandPlacement = .init(); model.preferences = prefs
                })) {
                    Text(model.t("Otomatik · MacBook, yoksa ana ekran", "Automatic · built-in, otherwise main")).tag(UInt32(0))
                    ForEach(NSScreen.screens, id: \.displayIdentifier) { screen in Text(screen.localizedName).tag(screen.displayIdentifier) }
                }
                Button(model.t("Adayı üst ortaya sıfırla", "Reset island to top center")) { model.resetIslandPosition?() }
                    .help(model.t("Kaydedilen sürükleme konumunu sıfırla", "Reset the saved drag position"))
                Toggle(model.t("Adayı tam ekran uygulamaların üzerinde göster", "Show island over full-screen apps"), isOn: $model.preferences.showOverFullscreen)
                HStack {
                    Text(model.t("Oturum kısayolu", "Session shortcut"))
                    Spacer()
                    Button(recording ? model.t("Tuşlara bas…", "Press shortcut…") : model.preferences.shortcutLabel) { startRecording() }
                        .font(.system(.body, design: .monospaced)).frame(minWidth: 110)
                }
                Text(model.t("Command, Control veya Option içeren bir kısayol seç. Reduce Motion sistemden uygulanır.", "Choose a shortcut with Command, Control or Option. Reduce Motion follows your system.")).font(.caption).foregroundStyle(Color(colors.secondary))
            }
        }
    }
    private var resetMascotColorButton: some View {
        Button(model.t("Varsayılana sıfırla", "Reset to default")) { model.preferences.resetSelectedMascotColor() }
            .controlSize(.small).disabled(model.preferences.mascotColors[model.preferences.mascot.rawValue] == nil)
            .help(model.t("Seçili karakter uygulama rengini izlesin", "Let the selected character follow the app accent"))
            .accessibilityLabel(model.t("Seçili karakter rengini varsayılana sıfırla", "Reset selected character color to default"))
    }
    private var integration: some View {
        VStack(alignment: .leading, spacing: 18) {
            group {
                Label(model.integrationBlocked ? model.t("Hook’lar ayar veya politika nedeniyle kapalı", "Hooks disabled by settings or policy") : model.integrationInstalled ? model.t("Claude bağlantısı kurulu", "Claude connection installed") : model.t("Bağlantı henüz kurulmadı", "Not connected yet"), systemImage: model.integrationInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.integrationInstalled ? SessionState.completed.tint : islandOrange)
                Text(model.claudeVersion.isEmpty ? model.t("Claude sürümü kontrol ediliyor…", "Checking Claude version…") : model.claudeVersion).font(.caption).foregroundStyle(Color(colors.secondary)).textSelection(.enabled)
                TextField(model.t("Claude yapılandırma dizini", "Claude configuration directory"), text: $model.configPath).textFieldStyle(.roundedBorder)
                HStack {
                    Button(model.t("Hook’ları incele ve kur", "Review & install hooks")) { showHookPreview = true }.buttonStyle(AccentButtonStyle()).disabled(model.integrationBlocked)
                    Button(model.t("Yenile", "Refresh")) { model.refreshIntegration() }
                    if model.integrationInstalled { Button(model.t("Bağlantıyı kaldır", "Remove connection")) { model.uninstallIntegration() } }
                }
                Text(model.t("Kurulumdan sonra mevcut Claude oturumlarını yeniden başlat. Projeye özel veya kurumsal ayarlar hook’ları engelleyebilir; gerçek bağlantıyı bir prompt göndererek doğrula.", "Restart existing Claude sessions after installation. Project or managed settings can block hooks; verify the real connection by sending a prompt."))
                    .font(.caption).foregroundStyle(Color(colors.secondary))
                Divider().padding(.vertical, 6)
                Text(model.t("VS Code pencere ve terminal seçimi", "VS Code window and terminal routing")).font(.headline)
                Text(model.t("Birden fazla proje/pencere içinden doğru Claude terminaline dönmek için yerel Dev Island eklentisini kur. Açık terminaller yeniden oluşturulmaz.", "Install the local Dev Island extension to return to the exact Claude terminal across projects and windows. Existing terminals are not recreated."))
                    .font(.callout).foregroundStyle(Color(colors.secondary))
                Button(model.t("VS Code bağlantısını kur / güncelle", "Install / update VS Code connection")) { model.installVSCodeConnector?() }
                    .disabled(model.installVSCodeConnector == nil)
            }
            group {
                sectionLabel(model.t("BAĞLANTIYI DOĞRULA", "VERIFY CONNECTION"))
                Text(model.t("Bu test paket içindeki gerçek köprüyü çalıştırır; Claude hesabına istek atmaz veya ayarlarını değiştirmez.", "This test runs the bundled bridge. It doesn’t call Claude or change its settings."))
                    .font(.callout).foregroundStyle(Color(colors.secondary))
                Button(model.t("Köprü testi gönder", "Send bridge test")) { model.testBridge(); model.showSessions?() }
                if let last = model.lastReceived {
                    HStack { Text(model.t("Son olay", "Last event")); Text(last, style: .relative) }.font(.caption).foregroundStyle(Color(colors.secondary))
                }
            }
            group {
                Text(model.t("Terminale geri dönüş", "Return to terminal")).font(.headline)
                Text(model.t("Önce olayın kaynak uygulaması seçilir. Kaynak belirsizse tek açık uygulama kullanılır; birden fazla aday varsa sorulur. Apple Terminal’de TTY eşleşmesi için Automation izni gerekebilir. VS Code bağlantısı, ilgili pencereyi ve terminali seçer. Cursor ve Warp uygulama düzeyinde açılır.", "The event’s source application takes priority. Unknown sources use the only running app or prompt you to choose. Apple Terminal TTY selection may request Automation permission. The VS Code connection selects the matching window and terminal. Cursor and Warp return at app level."))
                    .font(.callout).foregroundStyle(Color(colors.secondary))
                Button(model.t("Hatırlanan terminal tercihini sıfırla", "Reset remembered terminal choice")) { model.preferences.preferredTerminal = nil }
            }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            group {
                Picker(model.t("Dil", "Language"), selection: $model.preferences.language) {
                    Text(model.t("Sistem dili", "System language")).tag("system")
                    Text("Türkçe").tag("tr"); Text("English").tag("en")
                }
                Toggle(model.t("Girişte başlat", "Launch at login"), isOn: Binding(get: { loginEnabled }, set: { enable in
                    do {
                        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    } catch { model.status = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                }))
            }
            group {
                Toggle(model.t("Proje adlarını gizle", "Hide project names"), isOn: $model.preferences.hideProjects)
                Toggle(model.t("Ada içinde soru önizlemesini göster", "Show question preview inside the island"), isOn: $model.preferences.showPreview)
                Picker(model.t("Geçmiş saklama süresi", "History retention"), selection: $model.preferences.retentionDays) {
                    ForEach([1, 7, 14, 30], id: \.self) { day in Text(model.t("\(day) gün", "\(day) days")).tag(day) }
                }
                Text(model.t("Sistem bildirimleri her zaman genel durum metnini gösterir. Soru önizlemesi yalnızca bellekte bulunur. Proje yolu ve oturum metaverisi yerel SwiftData deposunda tutulur. Kod, komut, plan veya konuşma kaydedilmez.", "Native notifications always use generic status text. Question previews live only in memory. Project paths and session metadata are stored locally in SwiftData. Code, commands, plans and conversations are never recorded."))
                    .font(.callout).foregroundStyle(Color(colors.secondary))
                Button(model.t("Geçmişi temizle…", "Clear history…")) { confirmingClear = true }
                Button(model.t("Yerel veri klasörünü aç", "Open local data folder")) { NSWorkspace.shared.open(model.paths.root) }
            }
            notice(model.t("Uygulama sunucuya bağlanmaz ve telemetri göndermez. Uygulamadan çıkmak Claude’u durdurmaz.", "The app has no server connection or telemetry. Quitting it doesn’t stop Claude."), symbol: "lock.shield")
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.t("Son 200 olay", "Latest 200 events")).font(.caption).foregroundStyle(Color(colors.secondary))
                Spacer()
                Button(model.t("Temizle…", "Clear…")) { confirmingClear = true }
            }
            if model.ledger.history.isEmpty { notice(model.t("Henüz olay yok.", "No activity yet."), symbol: "clock") }
            ForEach(Array(model.ledger.history.suffix(200).reversed())) { event in
                HStack(spacing: 12) {
                    Image(systemName: event.state.symbol).foregroundStyle(event.state.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title(event.state)).font(.system(size: 12, weight: .medium))
                        Text(model.preferences.hideProjects ? String(event.sessionID.prefix(7)) : model.ledger.sessions[event.sessionID]?.title ?? String(event.sessionID.prefix(7)))
                            .font(.system(size: 10)).foregroundStyle(Color(colors.secondary))
                    }
                    Spacer()
                    Text(event.timestamp, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(colors.secondary))
                }.padding(12).background(Color(colors.canvas), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(colors.secondary)) }
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func notice(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(islandOrange)
            Text(text).font(.system(size: 12)).foregroundStyle(Color(colors.secondary))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(islandOrange.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
    private func ruleBinding(_ state: SessionState, _ key: WritableKeyPath<AlertRule, Bool>) -> Binding<Bool> {
        Binding(get: { model.preferences.rule(for: state)[keyPath: key] }, set: { value in
            var rule = model.preferences.rule(for: state); rule[keyPath: key] = value; model.preferences.rules[state.rawValue] = rule
        })
    }
    private func timePicker(_ label: String, value: Binding<Int>) -> some View {
        DatePicker(label, selection: Binding(get: {
            Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
    private func chooseSound() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let folder = model.paths.root.appendingPathComponent("Sounds")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = folder.appendingPathComponent("custom." + url.pathExtension)
                if url != destination {
                    try Data(contentsOf: url).write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
                model.preferences.customSoundPath = destination.path
            } catch { model.status = error.localizedDescription }
        }
    }
    private func startRecording() {
        stopRecording(); recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
            var carbon: UInt32 = 0, label = ""
            if flags.contains(.control) { carbon |= 4096; label += "⌃" }
            if flags.contains(.option) { carbon |= 2048; label += "⌥" }
            if flags.contains(.shift) { carbon |= 512; label += "⇧" }
            if flags.contains(.command) { carbon |= 256; label += "⌘" }
            label += event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"
            var preferences = model.preferences
            preferences.shortcutKey = UInt32(event.keyCode)
            preferences.shortcutModifiers = carbon
            preferences.shortcutLabel = label
            model.preferences = preferences
            stopRecording(); return nil
        }
    }
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; recording = false
    }
}
