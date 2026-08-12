import SwiftUI

struct NoteTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let koreanName: String
    let background: UInt32
    let foreground: UInt32
    let accent: UInt32
    let shadowOpacity: Double

    var backgroundColor: Color { Color(hex: background) }
    var foregroundColor: Color { Color(hex: foreground) }
    var accentColor: Color { Color(hex: accent) }

    func displayName(language: AppLanguage) -> String {
        language == .korean ? koreanName : name
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex & 0xFF0000) >> 16) / 255
        let green = Double((hex & 0x00FF00) >> 8) / 255
        let blue = Double(hex & 0x0000FF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
