struct CrashReporter {
    func flushOnRelease() {}
}

final class EventsTransport {}

struct EventsClient {
    let endpoint: String
    private let transport: EventsTransport

    init(endpoint: String, transport: EventsTransport = EventsTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }
}

func finishLaunch(reporter: CrashReporter) -> EventsClient? {
    #if !DEBUG
    reporter.flushOnRelease()
    return EventsClient(endpoint: "release")
    #else
    return nil
    #endif
}

enum PaletteSource {
    static let primary = "primary"
    static let secondary = "secondary"
}

enum Palette {
    static let colors: [String] = {
        #if DEBUG
        [PaletteSource.primary]
        #else
        [PaletteSource.primary, PaletteSource.secondary]
        #endif
    }()
}

final class Theme {
    var cachedColors: [String] = Palette.colors

    init() {
        cachedColors = []
    }
}
