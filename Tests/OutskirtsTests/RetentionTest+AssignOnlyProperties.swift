import SourceGraph
@testable import TestShared
import XCTest

extension RetentionTest {
    func testLetPropertyMutatedThroughSubscriptIsNotAssignOnly() {
        analyze(retainPublic: true, retainAssignOnlyProperties: false) {
            let globalLetCache = DeclarationDescription(kind: .varGlobal, name: "fixtureGlobalLetCache1800", line: nil)
            assertReferenced(globalLetCache)
            assertNotAssignOnlyProperty(globalLetCache)

            assertReferenced(.class("FixtureClass1800")) {
                for property in ["instanceLetCache", "initAssignedLetCache", "existentialLetCache", "nonmutatingLetBox", "memberLetCache", "tupleLetCacheA", "tupleLetCacheB", "varCache", "memberVarCache", "weakCache"] {
                    self.assertReferenced(.varInstance(property))
                    self.assertNotAssignOnlyProperty(.varInstance(property))
                }
                self.assertReferenced(.varStatic("staticLetCache"))
                self.assertNotAssignOnlyProperty(.varStatic("staticLetCache"))

                self.assertAssignOnlyProperty(.varInstance("unreadInitAssignedLet"))
                self.assertAssignOnlyProperty(.varInstance("unreadReassignedVarCache"))
            }
        }
    }
}
