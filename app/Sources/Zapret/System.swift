import AppKit
import ServiceManagement
import UserNotifications

/// Автозапуск приложения при входе в систему. Сам обход от этого не зависит:
/// его службы запускает launchd ещё до входа.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Уведомления macOS: о переподборе стратегий, о том, что сайты не открываются,
/// об обновлениях. О переключении VPN не сообщаем — это видно по значку.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var allowed = false

    func setUp() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.allowed = ok }
    }

    func post(_ text: String, title: String = "Zapret") {
        guard allowed else {
            // уведомления запрещены или приложение без подписи — хотя бы так
            let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            Task.detached { _ = await Shell.run("/usr/bin/osascript", ["-e", "display notification \"\(esc)\" with title \"\(title)\""]) }
            return
        }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Новые версии приложения — из релизов getpaintoo/zapret-mac на GitHub (файл Zapret.zip).
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var latest: String?
    @Published private(set) var working = false
    @Published var error: String?
    private var assetURL: URL?
    private var timer: Timer?
    var notify: ((String) -> Void)?

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var updateAvailable: Bool { latest.map { Updater.newer($0, than: current) } ?? false }

    func start() {
        Task { await check(silent: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(silent: true) }
        }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(silent: Bool) async {
        error = nil
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/getpaintoo/zapret-mac/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            if !silent { error = "GitHub не ответил" }
            return
        }
        let assets = json["assets"] as? [[String: Any]] ?? []
        assetURL = assets.first { ($0["name"] as? String) == "Zapret.zip" }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        let wasKnown = latest
        latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        if updateAvailable && assetURL == nil { if !silent { error = "В релизе \(tag) нет Zapret.zip" } }
        if updateAvailable && wasKnown != latest && silent { notify?("Доступна новая версия Zapret \(latest ?? "")") }
    }

    /// Скачивает Zapret.zip, подменяет приложение и перезапускает его. Новую службу
    /// поставит уже новое приложение — с паролем администратора, как при установке.
    func install() {
        guard let url = assetURL else { error = "Нечего ставить"; return }
        working = true
        error = nil
        Task {
            defer { working = false }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("zapret-update-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let (file, _) = try await URLSession.shared.download(from: url)
                let zip = tmp.appendingPathComponent("Zapret.zip")
                try fm.moveItem(at: file, to: zip)
                let unzip = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
                let app = tmp.appendingPathComponent("Zapret.app")
                guard unzip.code == 0, let b = Bundle(url: app), b.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw NSError(domain: "Zapret", code: 1, userInfo: [NSLocalizedDescriptionKey: "Архив обновления не тот"])
                }
                guard await Shell.run("/usr/bin/codesign", ["--verify", "--deep", app.path]).code == 0 else {
                    throw NSError(domain: "Zapret", code: 2, userInfo: [NSLocalizedDescriptionKey: "Подпись приложения не сходится"])
                }
                _ = await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                let here = Bundle.main.bundleURL
                _ = try fm.replaceItemAt(here, withItemAt: app)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; /usr/bin/open \(Shell.quote(here.path))"]
                try p.run()
                NSApp.terminate(nil)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
