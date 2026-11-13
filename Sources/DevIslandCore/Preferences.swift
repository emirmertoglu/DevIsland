import Foundation

public enum ThemeMode: String, Codable, CaseIterable {
    case system, light, dark, black
    /// Pure black follows the dark appearance but uses true-black surfaces that blend with the notch.
    public var isBlack: Bool { self == .black }
}
public enum SurfaceMaterial: String, Codable, CaseIterable { case liquid, frosted, opaque }
public enum GlassStyle: String, Codable, CaseIterable { case regular, clear }
public enum CompanionVisibility: String, Codable, CaseIterable { case both, island, mascot }
public struct MascotPlacement: Codable, Equatable {
    public var displayID: UInt32
    public var x: Double
    public var y: Double
    public init(displayID: UInt32 = 0, x: Double = 1, y: Double = 0) {
        self.displayID = displayID; self.x = x; self.y = y
    }
}

public struct AlertRule: Codable, Equatable {
    public var island: Bool
    public var notification: Bool
    public var sound: Bool
    public init(island: Bool = true, notification: Bool = true, sound: Bool = true) {
        self.island = island; self.notification = notification; self.sound = sound
    }
}

public struct Preferences: Codable {
    public var language = "system"
    public var quiet = false
    public var quietHours = false
    public var quietStart = 22 * 60
    public var quietEnd = 8 * 60
    public var volume: Double = 0.5
    public var soundMode = "system"
    public var soundName = "Glass"
    public var customSoundPath = ""
    public var reminders = false
    public var hideProjects = false
    public var showPreview = false
    public var showOverFullscreen = true
    public var displayID: UInt32 = 0
    public var preferredTerminal: String?
    public var shortcutKey: UInt32 = 2
    public var shortcutModifiers: UInt32 = 768 // command + shift
    public var shortcutLabel = "⇧⌘D"
    public var retentionDays = 7
    public var theme: ThemeMode = .system
    public var surface: SurfaceMaterial = .liquid
    public var glassStyle: GlassStyle = .regular
    public var accentHex = "D97757"
    public var appearanceVersion = 3
    public var mascot: MascotKind = .clawd
    public var mascotColors: [String: MascotColorPreference] = [:]
    public var surfaceDensity: Double = 0.35
    public var companionVisibility: CompanionVisibility = .both
    public var mascotHidden = false
    public var mascotSize: Double = 96
    public var mascotPlacement = MascotPlacement()
    public var islandPlacement = IslandPlacement()
    public var seenCompletions: [String: Date] = [:]
    public var rules: [String: AlertRule] = [
        "question": .init(), "plan": .init(), "permission": .init(),
        "completed": .init(sound: false), "failed": .init()
    ]
    public init() {}
    // Adding visual preferences must not discard existing notification/terminal settings.
    private enum CodingKeys: String, CodingKey {
        case language, quiet, quietHours, quietStart, quietEnd, volume, soundMode, soundName, customSoundPath
        case reminders, hideProjects, showPreview, showOverFullscreen, displayID, preferredTerminal
        case shortcutKey, shortcutModifiers, shortcutLabel, retentionDays, rules
        case theme, surface, glassStyle, accentHex, surfaceDensity, companionVisibility, mascotHidden, mascotSize, mascotPlacement, seenCompletions
        case appearanceVersion, mascot, mascotColors, islandPlacement
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        language = read(.language, language); quiet = read(.quiet, quiet); quietHours = read(.quietHours, quietHours)
        quietStart = read(.quietStart, quietStart); quietEnd = read(.quietEnd, quietEnd)
        volume = read(.volume, volume); soundMode = read(.soundMode, soundMode); soundName = read(.soundName, soundName)
        customSoundPath = read(.customSoundPath, customSoundPath); reminders = read(.reminders, reminders)
        hideProjects = read(.hideProjects, hideProjects); showPreview = read(.showPreview, showPreview)
        showOverFullscreen = read(.showOverFullscreen, showOverFullscreen); displayID = read(.displayID, displayID)
        preferredTerminal = try? c.decodeIfPresent(String.self, forKey: .preferredTerminal)
        shortcutKey = read(.shortcutKey, shortcutKey); shortcutModifiers = read(.shortcutModifiers, shortcutModifiers)
        shortcutLabel = read(.shortcutLabel, shortcutLabel); retentionDays = read(.retentionDays, retentionDays)
        rules.merge(read(.rules, [String: AlertRule]())) { _, saved in saved }
        theme = read(.theme, theme); surface = read(.surface, surface); glassStyle = read(.glassStyle, glassStyle)
        accentHex = read(.accentHex, accentHex)
        if read(.appearanceVersion, 2) < 3 && accentHex.uppercased() == "168E96" { accentHex = "D97757" }
        appearanceVersion = 3
        mascot = read(.mascot, mascot); mascotColors = read(.mascotColors, mascotColors)
        surfaceDensity = read(.surfaceDensity, surfaceDensity)
        companionVisibility = read(.companionVisibility, companionVisibility); mascotHidden = read(.mascotHidden, mascotHidden)
        mascotSize = read(.mascotSize, mascotSize); mascotPlacement = read(.mascotPlacement, mascotPlacement)
        seenCompletions = read(.seenCompletions, seenCompletions)
        islandPlacement = read(.islandPlacement, islandPlacement)
        volume = min(1, max(0, volume)); surfaceDensity = min(1, max(0, surfaceDensity)); mascotSize = min(160, max(64, mascotSize))
    }
    public mutating func resetAccent() { accentHex = "D97757" }
    public mutating func resetSelectedMascotColor() { mascotColors.removeValue(forKey: mascot.rawValue) }
    public func rule(for state: SessionState) -> AlertRule { rules[state.rawValue] ?? .init(island: false, notification: false, sound: false) }
    public func isQuiet(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        if quiet { return true }
        guard quietHours else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart == quietEnd { return true }
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }
}

public struct AttentionDecision: Equatable {
    public var island: Bool
    public var notification: Bool
    public var sound: Bool
    public static let silent = Self(island: false, notification: false, sound: false)
}

public enum AttentionEngine {
    public static func decide(session: AgentSession, preferences: Preferences, replay: Bool, now: Date = Date()) -> AttentionDecision {
        guard !replay, session.revalidated, !session.muted,
              !(session.snoozedUntil.map { $0 > now } ?? false), !preferences.isQuiet(at: now) else { return .silent }
        let rule = preferences.rule(for: session.state)
        return AttentionDecision(island: rule.island, notification: rule.notification, sound: rule.sound)
    }
}
