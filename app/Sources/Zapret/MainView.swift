import SwiftUI

/// Подписи состояния — для панели, подсказки значка и меню.
enum StateText {
    @MainActor
    static func title(_ m: Model) -> String {
        if let b = m.busy, b != .check { return m.busy == .on ? "Подбираю стратегии" : b.title.replacingOccurrences(of: "…", with: "") }
        if let p = m.progress, p.byDaemon { return "Сторож подбирает стратегии" }
        switch m.state {
        case .notInstalled: return "Служба не установлена"
        case .off: return "Выключен"
        case .direct: return "Работает"
        case .vpn(let app): return "Пауза — включён \(app)"
        case .paused(let until): return until.map { "Пауза до \(time($0))" } ?? "Пауза"
        case .down: return "Обход не отвечает"
        case .starting: return "Запускается"
        }
    }

    @MainActor
    static func subtitle(_ m: Model) -> String {
        if m.busy == .on || m.progress?.byDaemon == true {
            return m.progress?.label ?? "Сначала проверяю сохранённые стратегии"
        }
        if let b = m.busy { return b.title }
        switch m.state {
        case .notInstalled: return "Открой Zapret, чтобы поставить её"
        case .off: return "Нажми — подберу стратегии и включу обход"
        case .direct: return "YouTube и Discord идут через обход"
        case .vpn: return "Выключишь VPN — обход вернётся сам"
        case .paused: return "Сеть идёт напрямую, без обхода"
        case .down: return "Нажми, чтобы перезапустить"
        case .starting: return "Секунду…"
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f.string(from: d)
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        if Calendar.current.isDateInToday(d) { return "сегодня \(f.string(from: d))" }
        if Calendar.current.isDateInYesterday(d) { return "вчера \(f.string(from: d))" }
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: d)
    }
}

struct RootView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Header()
                Group {
                    if m.needsSetup || m.state == .notInstalled {
                        SetupView().transition(.opacity)
                    } else {
                        switch m.page {
                        case .main: MainView().transition(.opacity)
                        case .extras: ExtrasView().transition(.move(edge: .trailing).combined(with: .opacity))
                        case .logs: LogsView().transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.smooth(duration: 0.28), value: m.page)

            if m.drawerOpen {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.smooth(duration: 0.25)) { m.drawerOpen = false } }
                    .transition(.opacity)
                DrawerView()
                    .transition(.move(edge: .leading))
            }

            if let t = m.toast {
                VStack {
                    Spacer()
                    Text(t)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.thickMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .padding(.bottom, 58)
                        .padding(.horizontal, 20)
                        .onTapGesture { m.toast = nil }
                }
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: m.drawerOpen)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: m.toast)
    }
}

struct Header: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 10) {
            RoundButton(symbol: "line.3.horizontal") { m.drawerOpen.toggle() }
            Spacer()
            if m.page == .main || m.needsSetup {
                HStack(spacing: 7) {
                    Circle().fill(m.state.color).frame(width: 7, height: 7)
                        .shadow(color: m.state.color.opacity(0.7), radius: 3)
                    Text("Zapret").font(.system(size: 14, weight: .semibold, design: .rounded))
                }
            } else {
                Text(m.page == .extras ? "Дополнительно" : "Логи")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            Spacer()
            if m.page != .main && !m.needsSetup {
                RoundButton(symbol: "xmark") { m.page = .main }
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct RoundButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MainView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 6)
            BigButton()
            Spacer().frame(height: 22)
            Text(StateText.title(m))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
            Text(StateText.subtitle(m))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 3)
                .padding(.horizontal, 24)
            if !m.busyLine.isEmpty && m.busy == .on {
                Text(m.busyLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 6).padding(.horizontal, 20)
            }
            Spacer().frame(height: 16)
            if case .direct = m.state, m.busy == nil, !m.selecting {
                Engines()
            }
            PauseControl().padding(.top, 14)
            if m.dnsSpoofed {
                Button { m.page = .extras } label: {
                    Label("Провайдер подменяет DNS Google — выключи его", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.stop)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Palette.stop.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .help("Открыть «Дополнительно»")
            }
            Spacer(minLength: 10)
            BottomBar()
        }
        .animation(.smooth(duration: 0.3), value: m.state)
        .animation(.smooth(duration: 0.3), value: m.busy)
    }
}

/// Главная кнопка: выключен — ▶ (подобрать стратегии и включить), включён — ■ (выключить).
/// Во время подбора — кольцо с процентами, нажатие прерывает подбор.
struct BigButton: View {
    @EnvironmentObject var m: Model
    @State private var spin = false
    @State private var hover = false

    private var on: Bool { m.state.isEnabled }
    private var working: Bool { m.busy == .on || m.busy == .off || m.busy == .install || m.progress?.byDaemon == true }

    var body: some View {
        Button { m.toggleMain() } label: {
            ZStack {
                Circle().fill(Color.primary.opacity(0.035))
                Circle().stroke(ringColor.opacity(on || working ? 0.18 : 0.12), lineWidth: 7)
                if working {
                    if let p = m.progress {
                        Circle()
                            .trim(from: 0, to: max(0.03, CGFloat(p.percent) / 100))
                            .stroke(Palette.run, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.smooth(duration: 0.6), value: p.percent)
                    } else {
                        Circle()
                            .trim(from: 0, to: 0.22)
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                            .onAppear { spin = true }
                            .onDisappear { spin = false }
                    }
                } else if on {
                    Circle()
                        .stroke(ringColor, lineWidth: 7)
                        .shadow(color: ringColor.opacity(0.55), radius: 12)
                }
                center
            }
            .frame(width: 156, height: 156)
            .glassCircle()
            .scaleEffect(hover ? 1.02 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hover = h } }
        .disabled(m.busy != nil && m.busy != .on)
        .help(m.state == .down ? "Перезапустить обход" : on ? "Выключить обход" : "Подобрать стратегии и включить обход")
    }

    private var ringColor: Color {
        if working { return Palette.run }
        return on ? m.state.color : .secondary
    }

    @ViewBuilder private var center: some View {
        if working, let p = m.progress {
            VStack(spacing: 2) {
                Text("\(p.percent)%").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                if m.busy == .on { Text("прервать").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        } else if working {
            Image(systemName: m.busy == .off ? "stop.fill" : "play.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if m.state == .down {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Palette.stop.gradient)
        } else if on {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.stop.gradient)
                .frame(width: 42, height: 42)
                .shadow(color: Palette.stop.opacity(0.35), radius: 6, y: 2)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Palette.run.gradient)
                .offset(x: 4)
                .shadow(color: Palette.run.opacity(0.35), radius: 6, y: 2)
        }
    }
}

/// Зелёная кнопка — одинаковая и в активном, и в неактивном окне.
struct PrimaryStyle: ButtonStyle {
    var tint: Color = Palette.run
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(tint.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Переключатель: зелёный, когда включён, и одинаковый в активном и неактивном окне.
struct SwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Palette.run : Color.primary.opacity(0.16))
                Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
            }
            .frame(width: 36, height: 21)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            .opacity(enabled ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { configuration.isOn.toggle() } }
    }
}

/// Галочка в скруглённом квадрате.
struct CheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(configuration.isOn ? Palette.run : Color.primary.opacity(0.1))
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
            configuration.label
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

struct SmallStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(tint ?? Color.primary.opacity(0.08)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .fixedSize()
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Чем сейчас обходится YouTube и Discord.
struct Engines: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 8) {
            chip("YouTube", m.info["yt"])
            chip("Discord", m.info["ds"])
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
    }

    private func chip(_ name: String, _ value: String?) -> some View {
        VStack(spacing: 1) {
            Text(name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text((value ?? "—").replacingOccurrences(of: ", ", with: " · "))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Пауза с таймером: 15 минут, час или пока не снимешь.
/// Пауза с таймером: «Пауза» раскрывается в 15 минут, час или «пока не сниму».
struct PauseControl: View {
    @EnvironmentObject var m: Model
    @State private var open = false

    var body: some View {
        Group {
            if case .paused(let until) = m.state {
                Button { m.resume() } label: {
                    pill(symbol: "play.fill", text: until.map { "Продолжить · до \(StateText.time($0))" } ?? "Продолжить", tint: Palette.run)
                }
                .buttonStyle(PressStyle())
            } else if m.state.isEnabled && m.busy == nil && !m.selecting {
                if open {
                    HStack(spacing: 6) {
                        choice("15 мин", 15)
                        choice("1 час", 60)
                        choice("Пока не сниму", 0)
                        Button { withAnimation(.smooth(duration: 0.25)) { open = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { open = true } } label: {
                        pill(symbol: "pause.fill", text: "Пауза", tint: Palette.pause)
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .frame(height: 32)
        .onChange(of: m.state) { _, _ in open = false }
    }

    private func choice(_ title: String, _ minutes: Int) -> some View {
        Button {
            open = false
            m.pause(minutes: minutes)
        } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(Palette.pause.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Palette.pause.opacity(0.35)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }

    private func pill(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).frame(height: 32)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .contentShape(Capsule())
    }
}

struct BottomBar: View {
    @EnvironmentObject var m: Model
    @State private var spin = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Image(systemName: (m.info["net"] ?? "").hasPrefix("iPhone") ? "iphone" : "wifi")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                // тип сети и так виден по значку — оставляем адрес шлюза
                Text(m.info["net"].map { $0.components(separatedBy: " · ").last ?? $0 } ?? "нет сети")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if m.info["net_known"] == "1" {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(Palette.run.opacity(0.85))
                        .help("Стратегии для этой сети запомнены — при возвращении в неё они ставятся сразу")
                }
                Spacer(minLength: 8)
                Button { m.updateStrategies() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
                        Text("Обновить стратегии").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .disabled(m.busy != nil)
                .help(m.stratUpdated.map { "Версия \(m.info["strat_ver"] ?? "?"), проверено \(StateText.when($0))" } ?? "Скачать свежие стратегии и списки с GitHub")
                .onChange(of: m.busy) { _, b in spin = b == .update }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            LogoView(size: 76)
            Text(m.installedVersion == nil ? "Установить службу" : (!m.scriptMatches ? "Обновить службу до \(m.bundledVersion)" : "Разрешить управление"))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button { m.install() } label: {
                HStack(spacing: 8) {
                    if m.busy == .install { ProgressView().controlSize(.small).tint(.white) }
                    Text(m.busy == .install ? "Устанавливаю…" : (m.installedVersion == nil ? "Установить" : "Обновить"))
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(PrimaryStyle())
            .disabled(m.busy == .install)
            if let e = m.setupError {
                Text(e).font(.system(size: 11)).foregroundStyle(Palette.stop).multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            Spacer()
            Text("Дальше пароль не нужен: правило sudo разрешает приложению запускать только скрипт zapret-mac, который принадлежит root.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26).padding(.bottom, 18)
        }
    }

    private var text: String {
        if m.installedVersion != nil && m.scriptMatches {
            return "Служба стоит, но приложению нужно разрешение запускать её без пароля. macOS спросит пароль администратора."
        }
        return "Обход работает через службу zapret-mac: она включает его и переключает вместе с VPN, даже когда приложение закрыто. macOS один раз спросит пароль администратора."
    }
}

extension View {
    /// Liquid Glass на macOS 26; собранное старым Xcode — обычная подложка.
    @ViewBuilder func glassCircle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(Circle().fill(.thinMaterial))
        }
        #else
        self.background(Circle().fill(.thinMaterial))
        #endif
    }

}
