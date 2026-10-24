import AppKit
import Foundation

/// Что сейчас с обходом — по `zapret-mac.sh info` и тому, что делает само приложение.
enum ZState: Equatable {
    case notInstalled
    case off
    case direct               // обход работает
    case vpn(String)          // пауза: включён VPN (имя клиента)
    case paused(Date?)        // пауза вручную, до этого времени (nil — пока не снимут)
    case down                 // включён, но tpws или сторож не отвечают
    case starting

    var isEnabled: Bool {
        switch self { case .direct, .vpn, .paused, .down, .starting: return true; default: return false }
    }
}

/// Долгая команда, которую приложение сейчас выполняет.
enum Busy: Equatable {
    case on, off, pause, resume, update, sites, sitesSelect, dns, check, install, uninstall

    var title: String {
        switch self {
        case .on: return "Включаю…"
        case .off: return "Выключаю…"
        case .pause: return "Ставлю на паузу…"
        case .resume: return "Снимаю паузу…"
        case .update: return "Обновляю стратегии…"
        case .sites: return "Меняю свои сайты…"
        case .sitesSelect: return "Подбираю стратегию для сайтов…"
        case .dns: return "Меняю DNS…"
        case .check: return "Проверяю сайты…"
        case .install: return "Устанавливаю службу…"
        case .uninstall: return "Удаляю zapret-mac…"
        }
    }
}

struct CheckItem: Identifiable, Hashable {
    let ok: Bool
    let group: String      // Y, D, U
    let label: String
    var why = ""           // почему не открылось: тайм-аут, сброс, TLS…
    var id: String { group + label }
}

struct Progress: Equatable {
    let percent: Int
    let label: String
    let byDaemon: Bool
}

enum SiteState { case checking, ok, fail }

@MainActor
final class Model: ObservableObject {
    enum Page { case main, extras, logs }

    // навигация в панели
    @Published var page: Page = .main
    @Published var drawerOpen = false

    // служба
    @Published private(set) var info: [String: String] = [:]
    @Published private(set) var checks: [CheckItem] = []
    @Published private(set) var installedVersion: String?
    @Published private(set) var sudoOK = true
    @Published private(set) var scriptMatches = true   // скрипт в /opt — тот же, что в приложении
    @Published private(set) var setupChecked = false
    @Published var setupError: String?

    // то, что делает приложение
    @Published private(set) var busy: Busy?
    @Published private(set) var busyLine = ""
    @Published var toast: String?

    // свои сайты
    @Published private(set) var userSites: [String] = []
    @Published var siteStatus: [String: SiteState] = [:]
    @Published var scanning = false
    @Published var candidates: [Candidate] = []

    let bundledVersion = Paths.bundledScript.flatMap(Paths.scriptVersion) ?? "?"
    var onStateChange: (() -> Void)?
    var onSetupNeeded: (() -> Void)?
    private var setupAnnounced = false
    var notify: ((String) -> Void)?

    private var current: Process?
    private var refreshing = false
    private var refreshAgain = false
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var timer: Timer?
    private var toastTask: Task<Void, Never>?
    private let scanner = DomainScanner()

    struct Candidate: Identifiable, Hashable {
        let domain: String
        var selected: Bool
        let blocked: Bool?    // открылся ли напрямую: nil — не знаем (включён VPN)
        var id: String { domain }
    }

    // MARK: состояние

    var needsSetup: Bool {
        guard setupChecked else { return false }
        return installedVersion == nil || !scriptMatches || !sudoOK
    }

    var state: ZState {
        if setupChecked && installedVersion == nil { return .notInstalled }
        switch info["state"] {
        case "direct": return .direct
        case "vpn": return .vpn(info["vpn_app"].flatMap { $0.isEmpty ? nil : $0 } ?? "VPN")
        case "paused":
            let t = Double(info["pause_until"] ?? "0") ?? 0
            return .paused(t > 0 ? Date(timeIntervalSince1970: t) : nil)
        case "down", "nowd": return .down
        case "starting": return .starting
        default: return .off
        }
    }

    var progress: Progress? {
        guard let p = info["progress"] else { return nil }
        let parts = p.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let pct = Int(parts[0]) else { return nil }
        return Progress(percent: min(max(pct, 0), 100), label: parts[1], byDaemon: parts.count > 2 && parts[2] == "daemon")
    }

    /// Подбор идёт: запущен приложением или сторожем.
    var selecting: Bool { busy == .on || busy == .sitesSelect || progress?.byDaemon == true }

    var checkTime: Date? { Double(info["check_time"] ?? "").map { Date(timeIntervalSince1970: $0) } }
    var stratUpdated: Date? { Double(info["strat_updated"] ?? "").map { Date(timeIntervalSince1970: $0) } }
    var since: Date? { Double(info["since"] ?? "").map { Date(timeIntervalSince1970: $0) } }
    var userSitesOn: Bool { info["user_sites"] != "0" }
    var dnsOn: Bool { info["dns"] == "1" }
    var dnsSpoofed: Bool { info["dns_spoof"] == "1" }

    /// Для снимков панели (--snapshot): состояние без службы.
    func loadPreview(info: [String: String], checks: [CheckItem] = [], busy: Busy? = nil, busyLine: String = "",
                     installed: String? = "3.0", sudo: Bool = true, sites: [String] = [], status: [String: SiteState] = [:]) {
        self.info = info; self.checks = checks; self.busy = busy; self.busyLine = busyLine
        installedVersion = installed; sudoOK = sudo; setupChecked = true
        userSites = sites; siteStatus = status
        isPreview = true
    }
    private var isPreview = false

    // MARK: запуск

    func start() {
        Task {
            await checkSetup()
            await refresh()
        }
        watchRunDir()
        schedule(every: 20)
        lastEventTime = max(lastEventTime, Date().timeIntervalSince1970 - 60)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // сторож сам замечает пробуждение; приложению — обновить, что показывает
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refresh()
            }
        }
    }

    /// Панель открыта — обновляем чаще.
    func setPanelVisible(_ visible: Bool) {
        schedule(every: visible ? 4 : 20)
        if visible { Task { await refresh(); reloadUserSites() } }
    }

    private func schedule(every seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func checkSetup() async {
        let fm = FileManager.default
        installedVersion = fm.fileExists(atPath: Paths.script) ? Paths.scriptVersion(Paths.script) : nil
        // сравниваем весь файл, а не только версию: исправление без новой версии тоже надо поставить
        if let b = Paths.bundledScript {
            scriptMatches = fm.contentsEqual(atPath: b, andPath: Paths.script)
        }
        sudoOK = installedVersion == nil ? false : await Shell.sudoAllowed()
        setupChecked = true
        if installedVersion != nil && watcher == nil { watchRunDir() }
        onStateChange?()
        if needsSetup && !setupAnnounced { setupAnnounced = true; onSetupNeeded?() }
    }

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            guard FileManager.default.fileExists(atPath: Paths.script) else {
                if installedVersion != nil { await checkSetup() }
                info = [:]; checks = []
                onStateChange?()
                return
            }
            // info есть с 3.0; у старой службы скрипт попытался бы спросить пароль sudo
            guard let v = installedVersion, !Updater.newer("3.0", than: v) else {
                info = [:]; checks = []
                onStateChange?()
                return
            }
            let r = await Shell.run("/bin/bash", [Paths.script, "info"])
            var d: [String: String] = [:]
            var c: [CheckItem] = []
            for line in r.output.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
                if k == "chk" {
                    let p = v.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                    if p.count >= 3 { c.append(CheckItem(ok: p[0] == "ok", group: p[1], label: p[2], why: p.count > 3 ? p[3] : "")) }
                } else {
                    d[k] = v
                }
            }
            let changed = d != info
            info = d; checks = c
            if changed { onStateChange?() }
            readEvents()
        } while refreshAgain
    }

    /// Папку run пишет сторож: статус, ход подбора, итог проверки. Любая перемена в ней —
    /// повод перечитать состояние, и значок меняется сразу, как VPN включился.
    private func watchRunDir() {
        guard watcher == nil else { return }
        let fd = open(Paths.run, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if src.data.contains(.delete) || src.data.contains(.rename) { self.rewatch(); return }
                // сторож пишет несколько файлов подряд — даём ему закончить
                try? await Task.sleep(nanoseconds: 150_000_000)
                await self.refresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func rewatch() {
        watcher?.cancel(); watcher = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            watchRunDir()
            await refresh()
        }
    }

    // MARK: уведомления от сторожа

    private var lastEventTime: Double {
        get { UserDefaults.standard.double(forKey: "lastEventTime") }
        set { UserDefaults.standard.set(newValue, forKey: "lastEventTime") }
    }

    private func readEvents() {
        guard let text = try? String(contentsOfFile: Paths.events, encoding: .utf8) else { return }
        var newest = lastEventTime
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "|", maxSplits: 1)
            guard p.count == 2, let t = Double(p[0]), t > lastEventTime else { continue }
            notify?(String(p[1]))
            newest = max(newest, t)
        }
        lastEventTime = newest
    }

    // MARK: команды

    @discardableResult
    private func root(_ busy: Busy, _ args: String..., toastResult: Bool = true) async -> ShellResult {
        await root(busy, args, toastResult: toastResult)
    }

    @discardableResult
    private func root(_ busy: Busy, _ args: [String], toastResult: Bool = true) async -> ShellResult {
        self.busy = busy
        busyLine = ""
        onStateChange?()
        let r = await Shell.root(args, onLine: { [weak self] line in
            self?.busyLine = line.trimmingCharacters(in: .whitespaces)
        }, started: { [weak self] p in self?.current = p })
        current = nil
        self.busy = nil
        busyLine = ""
        if r.output.contains("a password is required") {
            sudoOK = false
            show("Нужно заново установить службу")
        } else if toastResult, let s = r.summary {
            show(s)
        }
        await refresh()
        onStateChange?()
        return r
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    /// Главная кнопка: выключен — включить с подбором, включён — выключить.
    func toggleMain() {
        guard busy == nil else {
            if busy == .on || busy == .sitesSelect { cancel() }
            return
        }
        Task {
            // «не отвечает» — перезапуск, а не выключение: так и написано под кнопкой
            if state.isEnabled && state != .down { await root(.off, "off") } else { await root(.on, "on") }
        }
    }

    func cancel() {
        guard let p = current, p.isRunning else { return }
        p.terminate()   // sudo передаёт сигнал скрипту, тот убирает за собой временные правила
        show("Подбор прерван")
    }

    func pause(minutes: Int) { Task { await root(.pause, "pause", String(minutes)) } }
    func resume() { Task { await root(.resume, "resume") } }
    func updateStrategies() { Task { await root(.update, "update-strategies") } }
    func setDNS(_ on: Bool) { Task { await root(.dns, "dns", on ? "on" : "off") } }
    func checkNow() { Task { await root(.check, "check-now", toastResult: false) } }

    func setUserSites(_ on: Bool) {
        Task {
            await root(.sites, "sites", on ? "on" : "off")
            if on { testSites() }
        }
    }

    func sitesSelect() {
        Task {
            await root(.sitesSelect, "sites-select")
            testSites()
        }
    }

    func uninstall() {
        Task {
            await root(.uninstall, "uninstall", "yes")
            LoginItem.set(false)
            await checkSetup()
            await refresh()
        }
    }

    // MARK: установка службы

    /// Один раз с паролем администратора: скрипт из приложения ставит себя в /opt и
    /// правило sudo. Через osascript — тогда окно пароля не держит интерфейс.
    func install() {
        guard let script = Paths.bundledScript else { setupError = "В приложении нет zapret-mac.sh"; return }
        setupError = nil
        Task {
            busy = .install
            busyLine = ""
            onStateChange?()
            let cmd = "/bin/bash \(Shell.quote(script)) gui-install \(Shell.quote(NSUserName())) 2>&1"
            let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let src = "do shell script \"\(esc)\" with prompt \"Zapret ставит службу обхода в /opt/zapret-mac.\" with administrator privileges"
            let r = await Shell.run("/usr/bin/osascript", ["-e", src])
            busy = nil
            if r.code != 0 {
                if r.output.contains("-128") { setupError = nil } else {
                    setupError = r.output.split(separator: "\n").last.map(String.init) ?? "Установка не удалась"
                }
            } else {
                show(ShellResult(code: 0, output: r.output).summary ?? "Служба установлена")
            }
            await checkSetup()
            await refresh()
            reloadUserSites()
        }
    }

    // MARK: свои сайты

    func reloadUserSites() {
        guard !isPreview else { return }
        let text = (try? String(contentsOfFile: Paths.userList, encoding: .utf8)) ?? ""
        userSites = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// «https://www.Сайт.рф/путь» → «xn--80aswg.xn--p1ai»
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var host = URL(string: s)?.host ?? URLComponents(string: s)?.host else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if host.hasSuffix(".") { host.removeLast() }
        let ok = host.contains(".") && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        return ok ? host : nil
    }

    /// Добавить сайт и найти домены, с которых он грузит картинки, скрипты и API.
    func addSite(_ input: String) {
        guard let domain = Model.normalize(input) else { show("Это не похоже на адрес сайта"); return }
        Task {
            await root(.sites, "site-add", domain)
            reloadUserSites()
            siteStatus[domain] = .checking
            candidates = []
            scanning = true
            // tpws перечитывает список не мгновенно
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let found = await scanner.scan(domain: domain, known: Set(userSites))
            let vpn: Bool = { if case .vpn = state { return true }; return false }()
            var list: [Candidate] = []
            await withTaskGroup(of: Candidate.self) { g in
                for d in found {
                    g.addTask {
                        // свой домен не в списках обхода идёт через tpws без изменений, то есть
                        // напрямую: не открылся — скорее всего, его тоже блокируют
                        let blocked: Bool? = vpn ? nil : !(await SiteProbe.opens(d))
                        return Candidate(domain: d, selected: blocked ?? isRelated(d, to: domain), blocked: blocked)
                    }
                }
                for await c in g { list.append(c) }
            }
            candidates = list.sorted { ($0.selected ? 0 : 1, $0.domain) < ($1.selected ? 0 : 1, $1.domain) }
            scanning = false
            if candidates.isEmpty { show("Других доменов у сайта не нашлось") }
            testSites([domain])
        }
    }

    func addCandidates() {
        let chosen = candidates.filter(\.selected).map(\.domain)
        candidates = []
        guard !chosen.isEmpty else { return }
        Task {
            await root(.sites, ["site-add"] + chosen)
            reloadUserSites()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            testSites(chosen)
        }
    }

    func removeSite(_ domain: String) {
        Task {
            await root(.sites, "site-del", domain, toastResult: false)
            siteStatus[domain] = nil
            reloadUserSites()
        }
    }

    /// Открываются ли свои сайты сейчас — так, как их видят программы.
    func testSites(_ only: [String]? = nil) {
        let list = only ?? userSites
        for d in list { siteStatus[d] = .checking }
        Task {
            await withTaskGroup(of: (String, Bool).self) { g in
                for d in list { g.addTask { (d, await SiteProbe.opens(d)) } }
                for await (d, ok) in g { siteStatus[d] = ok ? .ok : .fail }
            }
        }
    }

    // MARK: журналы

    static let logFiles: [(String, String)] = [
        ("Сторож", "watchdog.log"), ("Подбор", "select.log"), ("Обновления", "update.log"),
        ("tpws", "tpws.log"), ("utunws", "utunws.log"), ("Диагностика", "diag.log"),
    ]

    func readLog(_ file: String, lines: Int = 400) -> String {
        guard let text = try? String(contentsOfFile: "\(Paths.logs)/\(file)", encoding: .utf8) else { return "Журнал пока пуст." }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}

/// Открывается ли сайт у обычной программы: через pf и tpws, как браузер.
enum SiteProbe {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.connectionProxyDictionary = [:]
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"]
        return URLSession(configuration: c)
    }()

    static func opens(_ domain: String) async -> Bool {
        guard let url = URL(string: "https://\(domain)/") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await session.data(for: req)
            return resp is HTTPURLResponse
        } catch {
            return false
        }
    }
}
