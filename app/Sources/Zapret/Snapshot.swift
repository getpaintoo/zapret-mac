import AppKit
import SwiftUI

/// `Zapret --snapshot ПАПКА` — рисует панель в разных состояниях в PNG (светлая и тёмная
/// тема). Для проверки вёрстки и картинок в README; служба при этом не нужна.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        let base: [String: String] = [
            "version": "3.0", "mode": "transparent", "yt": "tpws, general", "ds": "utunws, SEQOVL", "us": "tpws, ALT9",
            "user_sites": "1", "dns": "0", "strat_ver": "2026102401", "strat_updated": "\(Int(Date().timeIntervalSince1970) - 3600)",
            "tpws_ver": "v72.13", "utunws_ver": "1.1.2", "utunws_up": "1", "net": "Wi-Fi · 192.168.1.1", "net_known": "1",
            "since": "\(Int(Date().timeIntervalSince1970) - 7200)", "check_time": "\(Int(Date().timeIntervalSince1970) - 600)", "check_via": "bypass",
        ]
        let checks = [CheckItem(ok: true, group: "D", label: "Discord"), CheckItem(ok: true, group: "D", label: "Discord: шлюз"),
                      CheckItem(ok: true, group: "Y", label: "YouTube"), CheckItem(ok: false, group: "U", label: "x.com", why: "тайм-аут")]
        func with(_ extra: [String: String]) -> [String: String] { base.merging(extra) { $1 } }
        let pauseTill = "\(Int(Date().timeIntervalSince1970) + 3000)"
        let cases: [(String, (Model) -> Void)] = [
            ("1-off", { $0.loadPreview(info: with(["state": "off"])) }),
            ("2-direct", { $0.loadPreview(info: with(["state": "direct"])) }),
            ("3-vpn", { $0.loadPreview(info: with(["state": "vpn", "vpn": "utun30", "vpn_app": "Happ"])) }),
            ("4-paused", { $0.loadPreview(info: with(["state": "paused", "pause_until": pauseTill])) }),
            ("5-selecting", { $0.loadPreview(info: with(["state": "off", "progress": "42|tpws: ALT2 — 3 из 16|gui"]), busy: .on, busyLine: " [ 3/16] ALT2       YouTube 2/3") }),
            ("6-setup", { $0.loadPreview(info: [:], installed: "2.3", sudo: false) }),
            ("7-drawer", { $0.loadPreview(info: with(["state": "direct"])); $0.drawerOpen = true }),
            ("8-extras", { m in
                m.loadPreview(info: with(["state": "direct"]), sites: ["rutracker.org", "x.com", "static.t-ru.org"],
                              status: ["rutracker.org": .ok, "x.com": .fail, "static.t-ru.org": .checking])
                m.candidates = [.init(domain: "t-ru.org", selected: true, blocked: true), .init(domain: "googletagmanager.com", selected: false, blocked: false)]
                m.page = .extras }),
            ("9-logs", { m in m.loadPreview(info: with(["state": "direct"]), checks: checks); m.page = .logs }),
        ]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, setup) in cases {
            for dark in [false, true] {
                let m = Model()
                setup(m)
                let size = PanelController.content
                let view = RootView()
                    .environmentObject(m)
                    .environmentObject(Updater())
                    .frame(width: size.width, height: size.height)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.95))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                win.orderBack(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(dir)/\(name)-\(dark ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                win.orderOut(nil)
                print(file)
            }
        }
    }
}
