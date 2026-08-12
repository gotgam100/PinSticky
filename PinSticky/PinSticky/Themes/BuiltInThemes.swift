enum BuiltInThemes {
    static let all: [NoteTheme] = [
        NoteTheme(id: "smile-yellow", name: "Smile Yellow", koreanName: "스마일 옐로우", background: 0xFFF22E, foreground: 0x202020, accent: 0x2F7BFF, shadowOpacity: 0.20),
        NoteTheme(id: "easy-blue", name: "Easy Blue", koreanName: "이지 블루", background: 0x92DDFB, foreground: 0x1558DD, accent: 0xFFF22E, shadowOpacity: 0.18),
        NoteTheme(id: "bubble-pink", name: "Bubble Pink", koreanName: "버블 핑크", background: 0xFF3E9E, foreground: 0xFFFFFF, accent: 0x7B3CFF, shadowOpacity: 0.24),
        NoteTheme(id: "nice-green", name: "Nice Green", koreanName: "나이스 그린", background: 0x09B875, foreground: 0xFFF22E, accent: 0x16D4FF, shadowOpacity: 0.18),
        NoteTheme(id: "violet-smile", name: "Violet Smile", koreanName: "바이올렛 스마일", background: 0x5632D9, foreground: 0xFFFFFF, accent: 0xCDB6FF, shadowOpacity: 0.28),
        NoteTheme(id: "quiet-ink", name: "Quiet Ink", koreanName: "콰이어트 잉크", background: 0x111111, foreground: 0xF7F7F2, accent: 0xFFF22E, shadowOpacity: 0.34)
    ]

    static let defaultTheme = all[0]

    static func theme(id: String) -> NoteTheme {
        all.first(where: { $0.id == id }) ?? defaultTheme
    }
}
