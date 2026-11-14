//  Theme.swift
//  ToobitSniper — dark terminal look & small helpers

import SwiftUI

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static let terminalBG = Color(hex: 0x0A0E14)
    static let terminalPanel = Color(hex: 0x11161F)
    static let terminalPanelAlt = Color(hex: 0x161D28)
    static let terminalBorder = Color(hex: 0x233043)
    static let terminalText = Color(hex: 0xD7DEE8)
    static let terminalMuted = Color(hex: 0x77839A)
    static let longGreen = Color(hex: 0x22C55E)
    static let shortRed = Color(hex: 0xEF4444)
    static let accentAmber = Color(hex: 0xF59E0B)
    static let accentCyan = Color(hex: 0x38BDF8)
    static let elitePurple = Color(hex: 0xA78BFA)
}

enum TerminalFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Color.terminalPanel)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.terminalBorder, lineWidth: 1))
            .cornerRadius(6)
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

enum Formatters {
    static func price(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.1f", v) }
        if v >= 1 { return String(format: "%.4f", v) }
        return String(format: "%.6f", v)
    }

    static func pct(_ v: Double) -> String {
        String(format: "%+.2f%%", v)
    }

    static func qty(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.0f", v) }
        if v >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

extension Signal {
    var directionColor: Color {
        direction == .long ? .longGreen : .shortRed
    }

    var tierColor: Color {
        switch scoreTier {
        case .elite: return .elitePurple
        case .strong: return .accentCyan
        case .aggressive: return .accentAmber
        }
    }
}
