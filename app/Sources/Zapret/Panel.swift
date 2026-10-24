import AppKit
import SwiftUI

/// Окно панели: без рамки, прозрачное, поверх всего. Может принимать ввод (поле для
/// доменов), не делая приложение активным — как меню.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false        // тень рисует SwiftUI — она масштабируется вместе с панелью
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Показ и скрытие: панель вырастает из значка в строке меню и уходит в него обратно.
final class PanelState: ObservableObject {
    @Published var shown = false
    @Published var anchor = UnitPoint(x: 0.5, y: 0)
}

@MainActor
final class PanelController {
    static let content = NSSize(width: 340, height: 548)
    static let margin: CGFloat = 26   // место под тень и «пружину»

    private let panel: FloatingPanel
    private let state = PanelState()
    private let model: Model
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private(set) var isOpen = false

    init(model: Model, updater: Updater) {
        self.model = model
        let size = NSSize(width: Self.content.width + Self.margin * 2, height: Self.content.height + Self.margin * 2)
        panel = FloatingPanel(size: size)
        let root = PanelRoot(ps: state)
            .environmentObject(model)
            .environmentObject(updater)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        applyTheme()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    func applyTheme() {
        switch UserDefaults.standard.string(forKey: "theme") {
        case "light": panel.appearance = NSAppearance(named: .aqua)
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil
        }
    }

    func toggle(from button: NSStatusBarButton) {
        if isOpen { hide() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        guard let bw = button.window else { return }
        hideWork?.cancel()
        let screen = bw.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        let icon = bw.frame
        let w = Self.content.width, h = Self.content.height, m = Self.margin
        // под значком, но не за краем экрана
        let left = min(max(icon.midX - w / 2, vis.minX + 8), vis.maxX - 8 - w)
        let top = icon.minY - 6
        panel.setFrameOrigin(NSPoint(x: left - m, y: top - h - m))
        state.anchor = UnitPoint(x: (icon.midX - left) / w, y: 0)

        state.shown = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        isOpen = true
        model.setPanelVisible(true)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { self.state.shown = true }
        }
        addMonitors()
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        model.setPanelVisible(false)
        withAnimation(.easeIn(duration: 0.16)) { state.shown = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
            self.model.drawerOpen = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func addMonitors() {
        removeMonitors()
        // щелчок мимо панели — в другой программе или на рабочем столе
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.hide() }; return nil }   // Esc
            return e
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Карточка панели с анимацией появления.
struct PanelRoot: View {
    @ObservedObject var ps: PanelState
    @AppStorage("theme") private var theme = "system"

    var body: some View {
        RootView()
            .frame(width: PanelController.content.width, height: PanelController.content.height)
            .background(VisualEffect())
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(ps.shown ? 0.3 : 0), radius: 24, y: 12)
            .scaleEffect(ps.shown ? 1 : 0.3, anchor: ps.anchor)
            .offset(y: ps.shown ? 0 : -8)
            .opacity(ps.shown ? 1 : 0)
            .blur(radius: ps.shown ? 0 : 6)
            .padding(PanelController.margin)
            .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }
}

/// Размытый фон окна — как у системных панелей, сам подстраивается под тему.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
