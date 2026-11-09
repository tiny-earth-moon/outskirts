import Foundation

/// Runs independent blocking work at the same time, such as SwiftPM subprocesses that each load the manifest. The
/// results come in the order of the work, and the error thrown is the one serial execution would have met first.
///
/// The work may capture non-`Sendable` state: every block has finished when the call returns, and the blocks given to
/// one call never touch the same mutable state.
enum Concurrently {
    static func run<First, Second>(_ first: @escaping () throws -> First, _ second: @escaping () throws -> Second) throws -> (First, Second) {
        nonisolated(unsafe) let first = first
        nonisolated(unsafe) let second = second
        nonisolated(unsafe) var firstResult: Result<First, Error>?
        nonisolated(unsafe) var secondResult: Result<Second, Error>?

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                firstResult = Result(catching: first)
            } else {
                secondResult = Result(catching: second)
            }
        }

        guard let firstResult, let secondResult else {
            preconditionFailure("concurrentPerform returned before running every iteration")
        }

        return try (firstResult.get(), secondResult.get())
    }

    static func map<Element, Value>(_ elements: [Element], _ transform: @escaping (Element) throws -> Value) throws -> [Value] {
        nonisolated(unsafe) let elements = elements
        nonisolated(unsafe) let transform = transform
        var results = [Result<Value, Error>?](repeating: nil, count: elements.count)

        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: elements.count) { index in
                buffer[index] = Result { try transform(elements[index]) }
            }
        }

        return try results.map { result in
            guard let result else {
                preconditionFailure("concurrentPerform returned before running every iteration")
            }

            return try result.get()
        }
    }
}
