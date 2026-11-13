import Foundation

public extension Array {
    @inlinable
    func group<U: Hashable>(by transform: (Element) -> U) -> [U: [Element]] {
        Dictionary(grouping: self, by: transform)
    }
}
