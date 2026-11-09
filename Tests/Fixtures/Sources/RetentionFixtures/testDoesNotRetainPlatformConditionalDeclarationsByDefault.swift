import Foundation

public class FixtureClass226Default {
    @available(iOS, unavailable)
    func unavailableOnIOS() {}

    private func onlyUsedOnIOS() {}

    public func entry() {
        #if os(iOS)
        onlyUsedOnIOS()
        #endif
    }
}
