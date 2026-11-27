enum PlatformProbe {
    static func isSupported() -> Bool {
        true
    }
}

enum SharedProbe {
    static func isAvailable() -> Bool {
        true
    }
}

enum DeviceGate {
    static func isOpen() -> Bool {
        true
    }

    static func resetForPlatform() {}
}

func probeDevice() -> Bool {
    #if os(watchOS)
    return SharedProbe.isAvailable()
    #else
    return DeviceGate.isOpen()
    #endif
}
