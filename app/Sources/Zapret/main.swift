import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let updater = Updater()
    let notifier = Notifier()
    private var status: StatusController!
    private var panel: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.setUp()
        model.notify = { [notifier] text in notifier.post(text) }
        updater.notify = { [notifier] text in notifier.post(text) }
        panel = PanelController(model: model, updater: updater)
        status = StatusController(model: model, panel: panel)
        model.onStateChange = { [weak self] in self?.status.update() }
        // службу надо поставить или обновить (первый запуск, новая версия) — сразу показываем панель
        model.onSetupNeeded = { [weak self] in self?.status.openPanel() }
        model.start()
        updater.start()

        let d = UserDefaults.standard
        if !d.bool(forKey: "launchedBefore") {
            d.set(true, forKey: "launchedBefore")
            LoginItem.set(true)   // по умолчанию — вместе с системой; выключается в «Дополнительно»
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.status.openPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        status.openPanel()   // открыли приложение ещё раз из Finder или Launchpad
        return false
    }
}

/// Значок в строке меню. Левый щелчок — панель, правый — короткое меню.
@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: Model
    private let panel: PanelController
    private var pulse: Timer?
    private var pulseOn = true

    init(model: Model, panel: PanelController) {
        self.model = model
        self.panel = panel
        super.init()
        if let b = item.button {
            b.target = self
            b.action = #selector(click(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
        }
        update()
    }

    func openPanel() {
        if let b = item.button, !panel.isOpen { panel.show(from: b) }
    }

    @objc private func click(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle(from: sender)
        }
    }

    func update() {
        let (g, c) = StatusIcon.glyph(for: model.state)
        let busy = model.selecting || model.busy == .on || model.busy == .install
        if busy {
            if pulse == nil {
                pulse = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pulseOn.toggle()
                        self.item.button?.image = StatusIcon.image(.play, .systemGreen, alpha: self.pulseOn ? 1 : 0.3)
                    }
                }
            }
        } else {
            pulse?.invalidate(); pulse = nil
            item.button?.image = StatusIcon.image(g, c)
        }
        item.button?.toolTip = "Zapret — " + StateText.title(model)
    }

    private func showMenu() {
        let m = NSMenu()
        let head = NSMenuItem(title: StateText.title(model), action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())
        let s = model.state
        if model.busy == nil {
            if s.isEnabled {
                if case .paused = s {
                    m.addItem(item("Продолжить") { $0.resume() })
                } else {
                    m.addItem(item("Пауза на 15 минут") { $0.pause(minutes: 15) })
                    m.addItem(item("Пауза на час") { $0.pause(minutes: 60) })
                    m.addItem(item("Пауза, пока не сниму") { $0.pause(minutes: 0) })
                }
                m.addItem(item("Выключить") { $0.toggleMain() })
            } else if s == .off {
                m.addItem(item("Включить") { $0.toggleMain() })
            }
            m.addItem(.separator())
        }
        m.addItem(item("Открыть Zapret") { [weak self] _ in self?.openPanel() })
        m.addItem(NSMenuItem(title: "Выйти из приложения", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        if let b = item.button {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
        }
    }

    private func item(_ title: String, _ act: @escaping (Model) -> Void) -> NSMenuItem {
        let i = ClosureItem(title: title, action: { [weak self] in if let m = self?.model { act(m) } })
        return i
    }
}

private final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { Snapshot.run(to: CommandLine.arguments[i + 1]) }
    exit(0)
}
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
