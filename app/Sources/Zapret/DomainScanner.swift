import AppKit
import WebKit

/// Ищет домены, с которых сайт грузит картинки, стили, скрипты и API: открывает его
/// в невидимом WebKit (через обход — сам сайт уже в списке) и собирает адреса загрузок.
/// Сайту часто мало своего домена: rutracker.org берёт картинки со static.t-ru.org.
@MainActor
final class DomainScanner: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var window: NSWindow?
    private var cont: CheckedContinuation<[String], Never>?
    private var timeout: Task<Void, Never>?

    private static let collect = """
    (function () {
      var h = {};
      function add(v) { try { var u = new URL(v, location.href); if (u.protocol.indexOf('http') === 0) h[u.hostname] = 1; } catch (e) {} }
      try { performance.getEntriesByType('resource').forEach(function (e) { add(e.name); }); } catch (e) {}
      document.querySelectorAll('script[src],img[src],iframe[src],source[src],video[src],audio[src],link[href][rel~="stylesheet"],link[href][rel~="preload"],link[href][rel~="icon"],link[href][rel~="preconnect"],link[href][rel~="dns-prefetch"]').forEach(function (el) {
        add(el.getAttribute('src') || el.getAttribute('href'));
      });
      add(location.href);
      return Object.keys(h);
    })()
    """

    /// Базовые домены, которых ещё нет в `known` и которые не сам сайт.
    func scan(domain: String, known: Set<String>) async -> [String] {
        let hosts = await load(URL(string: "https://\(domain)/")!)
        var out = Set<String>()
        let own = baseDomain(domain)
        for h in hosts {
            let host = h.lowercased()
            guard host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { continue }
            let b = baseDomain(host)
            if b == own || host.hasSuffix("." + domain) || host == domain { continue }
            if known.contains(b) || known.contains(host) { continue }
            out.insert(b)
        }
        return out.sorted()
    }

    private func load(_ url: URL) async -> [String] {
        await withCheckedContinuation { c in
            cont = c
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
            w.navigationDelegate = self
            w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            // WebKit не любит грузить страницы без окна: держим его за пределами экрана
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1280, height: 900),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = w
            win.orderBack(nil)
            web = w; window = win
            w.load(URLRequest(url: url, timeoutInterval: 15))
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                if !Task.isCancelled { self?.harvest() }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // скрипты сайта догружают своё после загрузки страницы
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.harvest()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish([]) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finish([]) }
    }

    private func harvest() {
        guard let web, cont != nil else { return }
        web.evaluateJavaScript(Self.collect) { [weak self] result, _ in
            Task { @MainActor in self?.finish(result as? [String] ?? []) }
        }
    }

    private func finish(_ hosts: [String]) {
        timeout?.cancel(); timeout = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        web = nil; window = nil
        if let c = cont { cont = nil; c.resume(returning: hosts) }
    }
}

/// «static.t-ru.org» → «t-ru.org», «img.bbc.co.uk» → «bbc.co.uk». Списки tpws учитывают
/// поддомены сами, поэтому добавлять хватает базового домена.
func baseDomain(_ host: String) -> String {
    let p = host.split(separator: ".").map(String.init)
    guard p.count > 2 else { return host }
    let second = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "msk", "spb"]
    if p[p.count - 1].count == 2 && second.contains(p[p.count - 2]) { return p.suffix(3).joined(separator: ".") }
    return p.suffix(2).joined(separator: ".")
}

/// Похож ли домен на сайт по названию (rutracker.org и rutracker.cc) — такой отмечаем
/// сразу, если не можем проверить, блокируют ли его.
func isRelated(_ candidate: String, to site: String) -> Bool {
    let stem = baseDomain(site).split(separator: ".").first.map(String.init) ?? site
    return stem.count >= 4 && candidate.contains(stem)
}
