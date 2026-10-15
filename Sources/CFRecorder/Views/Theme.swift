import AppKit
import SwiftUI

enum Theme {
    static let orange = Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0x00 / 255)

    /// JetBrains Mono when it's installed, otherwise the system monospace.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrains Mono", size: size) != nil {
            return .custom("JetBrains Mono", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

/// `// SECTION_NAME` with orange slashes.
struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Text("//").foregroundStyle(Theme.orange)
            Text(title.uppercased().replacingOccurrences(of: " ", with: "_"))
        }
        .font(Theme.mono(11, weight: .semibold))
        .tracking(0.5)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.mono(10)).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Rectangle()
                        .fill(Float(i) / 10 < level ? Theme.orange : Color.primary.opacity(0.12))
                        .frame(width: 4, height: 10)
                }
            }
        }
    }
}
