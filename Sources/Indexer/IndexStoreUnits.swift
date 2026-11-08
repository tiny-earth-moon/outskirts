import IndexStore

extension IndexStore {
    /// The units of the store, and the names of those that cannot be read. `units` from swift-index-store only prints
    /// a warning for an unreadable unit and moves on, which would silently drop the source file it describes.
    func readUnits() -> (units: [UnitReader], unreadable: [String]) {
        var units: [UnitReader] = []
        var unreadable: [String] = []

        for name in unitNames {
            do {
                try units.append(UnitReader(indexStore: self, unitName: name))
            } catch {
                unreadable.append(name)
            }
        }

        return (units, unreadable.sorted())
    }
}
