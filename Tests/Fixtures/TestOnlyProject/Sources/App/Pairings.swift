enum ContrastLevel {
    case regular
    case large

    var minimum: Double {
        self == .regular ? 4.5 : 3
    }
}

struct Backdrop {
    let base: String

    var shades: [String] {
        [base]
    }
}

struct ColorPairing {
    let name: String
    let foreground: String
    let surface: Backdrop
    let level: ContrastLevel

    var tokens: [String] {
        [name, foreground]
    }
}

struct RecordStamp {}

struct UnusedRecord {
    let stamp: RecordStamp
}
