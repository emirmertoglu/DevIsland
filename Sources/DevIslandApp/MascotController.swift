import AppKit
import SwiftUI
import Combine
import DevIslandCore

private final class MascotWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MascotInputView: NSView {
    var clicked: (() -> Void)?
    var moved: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var pose: ClawdPose = .idle
    var kind: MascotKind = .clawd
    var dragging = false
    private var down = NSPoint.zero
    private var original = NSPoint.zero
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    func containsCharacter(_ point: NSPoint) -> Bool {
        MascotSilhouette.contains(point: point, size: bounds.size, kind: kind, pose: pose)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { containsCharacter(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        down = NSEvent.mouseLocation; original = window?.frame.origin ?? .zero; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let cursor = NSEvent.mouseLocation
        let delta = NSPoint(x: cursor.x - down.x, y: cursor.y - down.y)
        if hypot(delta.x, delta.y) > 4 { dragging = true }
        if dragging { window?.setFrameOrigin(NSPoint(x: original.x + delta.x, y: original.y + delta.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { moved?() } else { clicked?() }
        dragging = false
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

struct DesktopMascotView: View {
    @ObservedObject var model: AppModel
    var active: Bool
    var body: some View {
        CompanionView(model: model, size: model.preferences.mascotSize, active: active)
            .accessibilityLabel(model.mascotName + model.t(" masaüstü maskotu", " desktop companion"))
            .accessibilityValue(model.title(model.companion.state))
    }
}

struct MascotTrayView: View {
    @Environment(\.colorScheme) private var systemScheme
    private var colors: ThemeColors { model.preferences.themeColors(systemScheme: systemScheme) }
    @ObservedObject var model: AppModel
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CompanionView(model: model, size: 36, active: model.mascotTrayVisible)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.mascotName).font(.system(size: 13, weight: .semibold))
                    Text(model.title(model.companion.state)).font(.system(size: 11)).foregroundStyle(Color(colors.secondary))
                }
                Spacer()
                if model.waitingCount > 0 { Text("\(model.waitingCount)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(colors.accent)) }
            }.padding(.horizontal, 18).padding(.top, 14)
            SessionTrayView(model: model, active: model.mascotTrayVisible, close: close)
        }
        .islandSurface(model.preferences, radius: 26)
        .appTheme(model.preferences)
        .onExitCommand(perform: close)
    }
}

@MainActor final class MascotController: NSObject {
    private let model: AppModel
    private let window: MascotWindow
    private let input = MascotInputView()
    private let tray: IslandPanel
    private var globalMouse: Any?
    private var localMouse: Any?
    private var outsideClick: Any?
    private var subscriptions = Set<AnyCancellable>()
    init(model: AppModel) {
        self.model = model
        window = MascotWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tray = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for panel in [window as NSPanel, tray] {
            panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        window.hasShadow = false; window.contentView = input
        input.clicked = { [weak self] in self?.toggleTray() }
        input.moved = { [weak self] in self?.savePosition() }
        input.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
        input.setAccessibilityRole(.button)
        input.setAccessibilityElement(true)
        input.setAccessibilityLabel(model.t("Clawd; oturumları göster", "Clawd; show sessions"))
        tray.becomesKeyOnlyIfNeeded = true; tray.hasShadow = true
        tray.escape = { [weak self] in self?.hideTray() }
        tray.contentView = PanelSizing.host(MascotTrayView(model: model, close: { [weak self] in self?.hideTray() }))
        model.$companion.receive(on: RunLoop.main).sink { [weak self] activity in
            self?.input.pose = activity.pose; self?.updateHitTesting()
        }.store(in: &subscriptions)
        model.$ledger.receive(on: RunLoop.main).sink { [weak self] _ in
            if self?.tray.isVisible == true { self?.placeTray() }
        }.store(in: &subscriptions)
        model.$visualsAwake.receive(on: RunLoop.main).sink { [weak self] _ in self?.layout() }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        model.resetMascotPosition = { [weak self] in
            self?.model.preferences.mascotPlacement = .init(); self?.layout()
        }
    }
    private var screen: NSScreen? {
        NSScreen.screens.first(where: { $0.displayIdentifier == model.preferences.mascotPlacement.displayID }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    func layout() {
        guard model.preferences.showsMascot, model.visualsAwake, let screen else {
            window.orderOut(nil); hideTray(); removeMouseTracking()
            input.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        applyAppearance(model.preferences, to: window); applyAppearance(model.preferences, to: tray)
        let size = CGSize(width: model.preferences.mascotSize, height: model.preferences.mascotSize)
        if !input.dragging {
            let origin = MascotLayout.origin(placement: model.preferences.mascotPlacement, frame: screen.visibleFrame, size: size)
            window.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        if input.subviews.isEmpty {
            let host = PanelSizing.host(DesktopMascotView(model: model, active: true))
            host.frame = input.bounds; host.autoresizingMask = [.width, .height]; input.addSubview(host)
        }
        input.pose = model.companion.pose
        input.kind = model.preferences.mascot
        input.setAccessibilityLabel(model.mascotName + model.t("; oturumları göster", "; show sessions"))
        window.orderFrontRegardless(); installMouseTracking(); updateHitTesting()
        if tray.isVisible { placeTray() }
    }
    private func savePosition() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) }) ?? screen else { return }
        model.preferences.mascotPlacement = MascotLayout.placement(origin: window.frame.origin, frame: screen.visibleFrame,
            size: window.frame.size, displayID: screen.displayIdentifier)
        // mouseUp still owns the drag; apply the final clamped origin explicitly.
        window.setFrameOrigin(MascotLayout.origin(placement: model.preferences.mascotPlacement, frame: screen.visibleFrame, size: window.frame.size))
        if tray.isVisible { placeTray() }
    }
    func toggleTray() {
        if tray.isVisible { hideTray(); return }
        model.markCompletionsSeen(); applyAppearance(model.preferences, to: tray)
        placeTray(); tray.orderFrontRegardless(); model.mascotTrayVisible = true
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.tray.frame.contains(NSEvent.mouseLocation) && !self.window.frame.contains(NSEvent.mouseLocation) { self.hideTray() }
            }
        }
    }
    private func placeTray() {
        guard let screen else { return }
        let width: CGFloat = min(400, screen.visibleFrame.width - 32)
        let height = PanelSizing.height(of: MascotTrayView(model: model, close: {}), width: width, maximum: min(580, screen.visibleFrame.height - 32))
        let frame = screen.visibleFrame
        let x = min(frame.maxX - width - 12, max(frame.minX + 12, window.frame.midX - width / 2))
        let above = window.frame.maxY + 8
        let y = above + height < frame.maxY - 12 ? above : max(frame.minY + 12, window.frame.minY - height - 8)
        tray.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    func hideTray() {
        model.mascotTrayVisible = false
        tray.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
    }
    private func installMouseTracking() {
        guard globalMouse == nil else { return }
        // Mouse movement monitors need no keyboard listening, Accessibility, or screen recording.
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateHitTesting() }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateHitTesting(); return event
        }
    }
    private func removeMouseTracking() {
        if let globalMouse { NSEvent.removeMonitor(globalMouse); self.globalMouse = nil }
        if let localMouse { NSEvent.removeMonitor(localMouse); self.localMouse = nil }
    }
    private func updateHitTesting() {
        guard !input.dragging else { window.ignoresMouseEvents = false; return }
        let point = input.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        window.ignoresMouseEvents = !input.containsCharacter(point)
    }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.tag = tag; menu.addItem(item)
        }
        add(model.t("Oturumları göster", "Show sessions"), #selector(showTrayAction))
        add(model.t("Maskotu gizle", "Hide mascot"), #selector(hideAction))
        menu.addItem(.separator())
        let sizes = NSMenu()
        for size in [72, 96, 128, 160] {
            let item = NSMenuItem(title: "\(size) pt", action: #selector(sizeAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = size; item.state = Int(model.preferences.mascotSize) == size ? .on : .off; sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: model.t("Boyut", "Size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes; menu.addItem(sizeItem)
        menu.addItem(.separator())
        add(model.t("Konumu sıfırla", "Reset position"), #selector(resetAction))
        add(model.t("Ayarlar…", "Settings…"), #selector(settingsAction))
        return menu
    }
    @objc private func showTrayAction() { if !tray.isVisible { toggleTray() } }
    @objc private func hideAction() { model.preferences.mascotHidden = true }
    @objc private func sizeAction(_ item: NSMenuItem) { model.preferences.mascotSize = Double(item.tag) }
    @objc private func resetAction() { model.resetMascotPosition?() }
    @objc private func settingsAction() { model.showSettings?() }
}
