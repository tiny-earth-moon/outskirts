import Foundation

enum FixtureGenericAllCasesEnum: CaseIterable {
    case first
    case second
}

func fixtureGenericAllCasesCount<T: CaseIterable>(_: T.Type) -> Int {
    T.allCases.count
}

public func fixtureGenericAllCasesRoot() {
    print(fixtureGenericAllCasesCount(FixtureGenericAllCasesEnum.self))
}
