import AppKit
import SwiftUI

// Native interpretation of the approved neo-Swiss direction. No webfonts or network assets.
@MainActor enum Ink {
    static let canvas = adaptive(0xFFFFFF, 0x141415)
    static let sidebar = adaptive(0xF6F6F4, 0x101011)
    static let raised = adaptive(0xF4F4F2, 0x222224)
    static let primary = adaptive(0x20211F, 0xEDEDEB)
    static let secondary = adaptive(0x646661, 0xABADA7)
    static let muted = adaptive(0x6C6F68, 0x94968F)
    static let rule = adaptive(0xE7E7E2, 0x30312E)
    static let accent = adaptive(0x3F654B, 0xA3C4AD)
    static let selection = adaptive(0xEEF2ED, 0x242D26)
    static let danger = adaptive(0xAA3732, 0xEB9690)
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

enum TypeStyle {
    static let body = Font.system(size: 14, weight: .regular)
    static let small = Font.system(size: 12, weight: .regular)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

struct Rule: View {
    var body: some View { Rectangle().fill(Ink.rule).frame(height: 1).accessibilityHidden(true) }
}
struct RuleVertical: View {
    var body: some View { Rectangle().fill(Ink.rule).frame(width: 1).accessibilityHidden(true) }
}
struct HarnessMark: View {
    var size: CGFloat = 24
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: CGPoint(x: 1, y: 1)); path.addLine(to: CGPoint(x: 1, y: 23)); path.addLine(to: CGPoint(x: 8, y: 23))
            path.move(to: CGPoint(x: 23, y: 23)); path.addLine(to: CGPoint(x: 23, y: 1)); path.addLine(to: CGPoint(x: 16, y: 1))
            path.move(to: CGPoint(x: 7, y: 9)); path.addLine(to: CGPoint(x: 17, y: 9))
            path.move(to: CGPoint(x: 7, y: 15)); path.addLine(to: CGPoint(x: 17, y: 15))
            context.stroke(path, with: .color(Ink.primary), style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
        }.frame(width: 24, height: 24).scaleEffect(size / 24).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? Ink.canvas : destructive ? Ink.danger : Ink.primary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(primary ? (destructive ? Ink.danger : Ink.primary) : (configuration.isPressed ? Ink.raised : Ink.canvas))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? Color.clear : Ink.rule, lineWidth: 1))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.76 : 1)
    }
}
struct PlainIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .regular)).foregroundStyle(Ink.secondary)
            .frame(width: 32, height: 32)
            .background(configuration.isPressed ? Ink.rule : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
struct Keycap: View {
    let value: String
    var body: some View {
        Text(value).font(TypeStyle.mono).foregroundStyle(Ink.muted).padding(.horizontal, 4).padding(.vertical, 2)
            .background(Ink.canvas).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.rule, lineWidth: 1))
    }
}
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var compact = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Ink.muted).accessibilityHidden(true)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: compact ? 12 : 13))
                .focused($focused).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Ink.muted).accessibilityLabel("Clear search")
            } else if !compact { Keycap(value: "⌘ F") }
        }.padding(.horizontal, 12).frame(height: compact ? 32 : 36)
            .background(Ink.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Ink.secondary : Ink.rule, lineWidth: 1))
            .onReceive(NotificationCenter.default.publisher(for: .focusInventorySearch)) { _ in if !compact { focused = true } }
    }
}

extension Notification.Name {
    static let focusInventorySearch = Notification.Name("HarnessManager.focusSearch")
    static let refreshInventory = Notification.Name("HarnessManager.refresh")
}
