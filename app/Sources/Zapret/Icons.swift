import AppKit
import SwiftUI

/// Цвета состояний — те же, что у значка в строке меню.
enum Palette {
    static let run = Color(nsColor: .systemGreen)
    static let pause = Color(nsColor: .systemYellow)
    static let stop = Color(nsColor: .systemRed)
}

extension ZState {
    var color: Color {
        switch self {
        case .direct, .starting: return Palette.run
        case .vpn, .paused: return Palette.pause
        case .down: return Palette.stop
        case .off, .notInstalled: return .secondary
        }
    }
}

/// Значок в строке меню: ▶ зелёный — обход работает, ⏸ жёлтый — пауза (VPN или вручную),
/// ■ красный — выключен. Пока идёт подбор, треугольник мигает.
enum StatusIcon {
    enum Glyph { case play, pause, stop, playHollow, stopHollow }

    static func glyph(for state: ZState) -> (Glyph, NSColor) {
        switch state {
        case .direct, .starting: return (.play, .systemGreen)
        case .vpn, .paused: return (.pause, .systemYellow)
        case .off: return (.stop, .systemRed)
        case .down: return (.playHollow, .systemRed)
        case .notInstalled: return (.stopHollow, .secondaryLabelColor)
        }
    }

    static func image(_ g: Glyph, _ color: NSColor, alpha: CGFloat = 1) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = color.withAlphaComponent(alpha)
            c.setFill(); c.setStroke()
            switch g {
            case .play, .playHollow:
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 5.2, y: 3.6))
                p.line(to: NSPoint(x: 5.2, y: 14.4))
                p.line(to: NSPoint(x: 14.6, y: 9))
                p.close()
                p.lineJoinStyle = .round
                p.lineWidth = g == .play ? 2.2 : 1.6
                if g == .play { p.fill() }
                p.stroke()
            case .pause:
                NSBezierPath(roundedRect: NSRect(x: 4.4, y: 3.5, width: 3.5, height: 11), xRadius: 1.3, yRadius: 1.3).fill()
                NSBezierPath(roundedRect: NSRect(x: 10.1, y: 3.5, width: 3.5, height: 11), xRadius: 1.3, yRadius: 1.3).fill()
            case .stop:
                NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 10, height: 10), xRadius: 2.6, yRadius: 2.6).fill()
            case .stopHollow:
                let p = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 4.6, width: 8.8, height: 8.8), xRadius: 2.2, yRadius: 2.2)
                p.lineWidth = 1.4
                p.stroke()
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Zapret"
        return img
    }
}

/// Логотип: зелёный треугольник в кольце — как главная кнопка.
struct LogoView: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            Circle()
                .stroke(Palette.run.opacity(0.9), lineWidth: size * 0.06)
                .frame(width: size * 0.62, height: size * 0.62)
                .shadow(color: Palette.run.opacity(0.6), radius: size * 0.08)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.24, weight: .bold))
                .foregroundStyle(Palette.run)
                .offset(x: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}
