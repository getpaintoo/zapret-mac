import AppKit
import SwiftUI

// MARK: шторка

struct DrawerView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                LogoView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zapret").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(versionLine).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 18)

            item("Главная", "power", .main)
            item("Дополнительно", "slider.horizontal.3", .extras)
            item("Логи", "list.bullet.rectangle", .logs)

            Spacer()

            if updater.updateAvailable {
                DrawerRow(title: "Обновить до \(updater.latest ?? "")", symbol: "arrow.down.circle.fill", tint: Palette.run) {
                    updater.install()
                }
            }
            DrawerRow(title: "Выйти из Zapret", symbol: "rectangle.portrait.and.arrow.right", tint: .secondary) {
                NSApp.terminate(nil)
            }
            Text("Обход продолжит работать в фоне").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 236)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffect())
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
    }

    private var versionLine: String {
        let s = m.installedVersion.map { "служба \($0)" } ?? "служба не установлена"
        return "версия \(updater.current) · \(s)"
    }

    private func item(_ title: String, _ symbol: String, _ page: Model.Page) -> some View {
        DrawerRow(title: title, symbol: symbol, tint: m.page == page ? Palette.run : .primary, selected: m.page == page) {
            m.page = page
            withAnimation(.smooth(duration: 0.25)) { m.drawerOpen = false }
        }
    }
}

struct DrawerRow: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(tint).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : (hover ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: общие кусочки

struct SectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SwitchRow: View {
    let title: String
    let caption: String?
    let isOn: Bool
    var disabled = false
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let caption { Caption(caption) }
            }
        }
        .toggleStyle(SwitchStyle())
        .disabled(disabled)
    }
}

// MARK: дополнительно

struct ExtrasView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var updater: Updater
    @AppStorage("theme") private var theme = "system"
    @State private var input = ""
    @State private var loginOn = LoginItem.isOn
    @State private var loginError: String?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                sites
                SectionCard {
                    SwitchRow(title: "Запускать вместе с системой", caption: "Значок появится сам после входа. Обход работает и без него.",
                              isOn: loginOn) { on in
                        loginError = LoginItem.set(on)
                        loginOn = LoginItem.isOn
                    }
                    if LoginItem.needsApproval {
                        Caption("Разреши Zapret в «Системные настройки → Основные → Объекты входа».")
                    }
                    if let e = loginError { Caption(e) }
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Тема").font(.system(size: 13, weight: .medium))
                        Picker("", selection: $theme) {
                            Text("Как в системе").tag("system")
                            Text("Светлая").tag("light")
                            Text("Тёмная").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Divider().opacity(0.5)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Версия \(updater.current)").font(.system(size: 13, weight: .medium))
                            if let e = updater.error { Caption(e) }
                            else if updater.updateAvailable { Caption("Доступна \(updater.latest ?? "")") }
                            else if updater.latest != nil { Caption("Последняя") }
                        }
                        Spacer()
                        if updater.working { ProgressView().controlSize(.small) }
                        else if updater.updateAvailable {
                            Button("Обновить") { updater.install() }.buttonStyle(SmallStyle(tint: Palette.run))
                        } else {
                            Button("Проверить") { Task { await updater.check(silent: false) } }.buttonStyle(SmallStyle())
                        }
                    }
                }
                SectionCard {
                    SwitchRow(title: "DNS Google и Cloudflare", caption: "8.8.8.8 и 1.1.1.1 вместо DNS провайдера. В России с августа 2026 года ТСПУ подменяет их ответы — обычно лучше выключить.",
                              isOn: m.dnsOn, disabled: m.busy != nil) { m.setDNS($0) }
                    if m.dnsSpoofed {
                        Text("Провайдер подменяет ответы этих DNS: YouTube для них «не существует». Выключи — DNS роутера отвечает правильно.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.stop)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SectionCard {
                    if confirmRemove {
                        Text("Удалить zapret-mac?").font(.system(size: 13, weight: .semibold))
                        Caption("Обход выключится, правила pf, прокси и DNS вернутся как были, папка /opt/zapret-mac будет удалена. Само приложение останется — его можно перетащить в корзину.")
                        HStack {
                            Button("Удалить", role: .destructive) { confirmRemove = false; m.uninstall() }
                                .buttonStyle(SmallStyle(tint: Palette.stop))
                            Button("Отмена") { confirmRemove = false }.buttonStyle(SmallStyle())
                        }
                    } else {
                        Button { confirmRemove = true } label: {
                            Label("Удалить zapret-mac…", systemImage: "trash").font(.system(size: 13)).foregroundStyle(Palette.stop)
                        }
                        .buttonStyle(.plain)
                        .disabled(m.busy != nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .onAppear {
            loginOn = LoginItem.isOn
            m.reloadUserSites()
        }
    }

    // свои сайты: включить, вписать домен, связанные домены, список с проверкой
    private var sites: some View {
        SectionCard {
            SwitchRow(title: "Свои сайты", caption: "Пускать через обход домены из списка ниже.",
                      isOn: m.userSitesOn, disabled: m.busy != nil) { m.setUserSites($0) }
            if m.userSitesOn {
                HStack(spacing: 8) {
                    TextField("rutracker.org", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.run.opacity(input.isEmpty ? 0.25 : 0.9)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || m.busy != nil || m.scanning)
                }
                Caption("Поддомены учитываются сами: example.com покрывает и *.example.com.")

                if m.scanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Caption("Открываю сайт и ищу домены, с которых он грузит картинки и скрипты…")
                    }
                }
                if !m.candidates.isEmpty { candidates }

                if !m.userSites.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(m.userSites, id: \.self) { d in siteRow(d) }
                    }
                    HStack(spacing: 8) {
                        Button("Проверить") { m.testSites() }.buttonStyle(SmallStyle()).disabled(m.busy != nil)
                        if m.userSites.contains(where: { m.siteStatus[$0] == .fail }) {
                            Button("Подобрать стратегию") { m.sitesSelect() }
                                .buttonStyle(SmallStyle(tint: Palette.run))
                                .disabled(m.busy != nil)
                                .help("Перебрать стратегии tpws для своих сайтов — до пары минут")
                        }
                        Spacer()
                        if m.busy == .sitesSelect, let p = m.progress {
                            Caption("\(p.percent)%")
                        }
                    }
                    if case .vpn = m.state { Caption("Сейчас включён VPN — проверка показывает, как сайты открываются через него.") }
                }
            }
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Сайт грузит ещё и с этих доменов").font(.system(size: 12, weight: .semibold))
            Caption("Отмечены те, что не открылись напрямую, — скорее всего, их тоже блокируют.")
            ForEach($m.candidates) { $c in
                Toggle(isOn: $c.selected) {
                    HStack(spacing: 6) {
                        Text(c.domain).font(.system(size: 12, design: .monospaced))
                        if c.blocked == true {
                            Text("не открылся").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.stop)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.stop.opacity(0.12)))
                        }
                    }
                }
                .toggleStyle(CheckStyle())
            }
            HStack {
                Button("Добавить отмеченные (\(m.candidates.filter(\.selected).count))") { m.addCandidates() }
                    .buttonStyle(SmallStyle(tint: Palette.run))
                    .disabled(!m.candidates.contains(where: \.selected))
                Button("Не надо") { m.candidates = [] }.buttonStyle(SmallStyle())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func siteRow(_ d: String) -> some View {
        HStack(spacing: 8) {
            Group {
                switch m.siteStatus[d] {
                case .checking: ProgressView().controlSize(.mini)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.run)
                case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.stop)
                case nil: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12)).frame(width: 16)
            Text(d).font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
            Spacer()
            Button { m.removeSite(d) } label: {
                Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(m.busy != nil)
            .help("Убрать из своих сайтов")
        }
        .padding(.vertical, 3)
    }

    private func add() {
        let t = input
        input = ""
        m.addSite(t)
    }
}

// MARK: логи

struct LogsView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text("Обзор").tag(0)
                Text("Системные").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            if tab == 0 { OverviewView() } else { SystemLogView() }
        }
        .padding(.top, 4)
    }
}

struct OverviewView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard {
                    row("Состояние", StateText.title(m))
                    if let s = m.since, m.state.isEnabled { row("Состояние с", StateText.when(s)) }
                    row("Сеть", (m.info["net"] ?? "нет") + (m.info["net_known"] == "1" ? " · запомнена" : ""))
                    if case .vpn(let app) = m.state { row("VPN", "\(app) (\(m.info["vpn"] ?? ""))") } else { row("VPN", "выключен") }
                    row("Режим", m.info["mode"] == "socks" ? "SOCKS-прокси" : "прозрачный")
                }
                SectionCard {
                    row("YouTube", pretty(m.info["yt"]))
                    row("Discord", pretty(m.info["ds"]))
                    if m.userSitesOn { row("Свои сайты", pretty(m.info["us"])) }
                    row("Стратегии", "версия \(m.info["strat_ver"] ?? "—")" + (m.stratUpdated.map { " · проверено \(StateText.when($0))" } ?? ""))
                    row("tpws", m.info["tpws_ver"] ?? "—")
                    row("utunws", (m.info["utunws_ver"] ?? "—") + (m.info["utunws_up"] == "1" ? " · работает" : " · не запущен"))
                    row("DNS", m.dnsOn ? "Google и Cloudflare" : "как в системе")
                }
                SectionCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Последняя проверка").font(.system(size: 13, weight: .semibold))
                            if let t = m.checkTime {
                                Caption("\(StateText.when(t)) · \(via)")
                            } else {
                                Caption("Сторож проверяет сайты раз в полчаса и после смены сети")
                            }
                        }
                        Spacer()
                        Button { m.checkNow() } label: {
                            if m.busy == .check { ProgressView().controlSize(.small) } else { Text("Проверить сейчас") }
                        }
                        .buttonStyle(SmallStyle())
                        .disabled(m.busy != nil)
                    }
                    ForEach(m.checks) { c in
                        HStack(spacing: 8) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Palette.run : Palette.stop).font(.system(size: 12))
                            Text(c.label).font(.system(size: 12))
                            if !c.why.isEmpty { Text(c.why).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(group(c.group)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var via: String {
        switch m.info["check_via"] {
        case "vpn": return "через VPN"
        case "direct": return "без обхода"
        default: return "через обход"
        }
    }

    private func group(_ g: String) -> String { g == "Y" ? "YouTube" : g == "D" ? "Discord" : "свой сайт" }
    private func pretty(_ s: String?) -> String { (s ?? "—").replacingOccurrences(of: ", ", with: " · ") }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(v).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

struct SystemLogView: View {
    @EnvironmentObject var m: Model
    @State private var file = "watchdog.log"
    @State private var text = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $file) {
                    ForEach(Model.logFiles, id: \.1) { name, f in Text(name).tag(f) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); m.show("Журнал скопирован") } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help("Скопировать")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "\(Paths.logs)/\(file)")]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain).help("Показать в Finder")
            }
            .padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .onAppear { reload(); proxy.scrollTo("end") }
                .onChange(of: file) { _, _ in reload(); proxy.scrollTo("end") }
                .onChange(of: text) { _, _ in proxy.scrollTo("end") }
                .onReceive(tick) { _ in reload() }
            }
        }
    }

    private func reload() {
        let t = m.readLog(file)
        if t != text { text = t }
    }
}
