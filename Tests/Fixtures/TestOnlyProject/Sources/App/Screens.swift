struct AppScreen {
    func show() {}
}

struct SnapshotOnlyView {
    func render() -> String {
        "badge"
    }
}

struct SharedFormatter {
    func format() -> String {
        "shared"
    }
}

struct Settings {
    func usedByApp() {}
    func usedOnlyByTests() {}
}
