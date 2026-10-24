import Foundation

/// Где живёт zapret-mac. Папка принадлежит root: приложение только читает её,
/// а меняет через `sudo -n /opt/zapret-mac/zapret-mac.sh …` (правило ставит gui-install).
enum Paths {
    static let dir = "/opt/zapret-mac"
    static let script = "\(dir)/zapret-mac.sh"
    static let run = "\(dir)/run"
    static let logs = "\(dir)/log"
    static let userList = "\(dir)/lists/list-user.txt"
    static let events = "\(run)/events"

    /// Копия скрипта внутри приложения — её gui-install ставит в /opt.
    static var bundledScript: String? { Bundle.main.path(forResource: "zapret-mac", ofType: "sh") }

    /// Версия из строки ZM_VERSION="…" скрипта.
    static func scriptVersion(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", maxSplits: 80) where line.hasPrefix("ZM_VERSION=\"") {
            return line.dropFirst("ZM_VERSION=\"".count).split(separator: "\"").first.map(String.init)
        }
        return nil
    }
}

struct ShellResult {
    let code: Int32
    let output: String

    /// Последняя строка-итог скрипта (✓, ! или ✗) — её показываем как сообщение.
    var summary: String? {
        output.split(separator: "\n").reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("✓") || $0.hasPrefix("!") || $0.hasPrefix("✗") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
    }
}

enum Shell {
    /// Запускает программу и ждёт её. Строки вывода по мере появления отдаются в `onLine`
    /// (на главном потоке), а сам процесс — в `started`, чтобы его можно было прервать.
    static func run(_ path: String, _ args: [String],
                    onLine: (@MainActor (String) -> Void)? = nil,
                    started: (@MainActor (Process) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["LANG"] = "en_US.UTF-8"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice

            let buf = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                let lines = buf.append(d)
                if let onLine, !lines.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach(onLine) } }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let out = buf.finish(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ShellResult(code: proc.terminationStatus, output: out))
            }
            do {
                try p.run()
                if let started { DispatchQueue.main.async { MainActor.assumeIsolated { started(p) } } }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ShellResult(code: -1, output: error.localizedDescription))
            }
        }
    }

    /// Команда скрипта от root без пароля.
    static func root(_ args: [String], onLine: (@MainActor (String) -> Void)? = nil,
                     started: (@MainActor (Process) -> Void)? = nil) async -> ShellResult {
        await run("/usr/bin/sudo", ["-n", Paths.script] + args, onLine: onLine, started: started)
    }

    /// Разрешено ли приложению запускать скрипт без пароля.
    static func sudoAllowed() async -> Bool {
        await run("/usr/bin/sudo", ["-n", "-l", Paths.script]).code == 0
    }

    /// Строка для оболочки в одинарных кавычках.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Вывод процесса: целые строки по мере появления и весь текст в конце.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var all = Data()

    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(d); all.append(d)
        var lines: [String] = []
        while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines
    }

    func finish(_ rest: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        all.append(rest)
        return String(decoding: all, as: UTF8.self)
    }
}
