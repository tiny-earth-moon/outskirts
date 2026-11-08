#if os(macOS)
    import Configuration
    import Foundation
    @testable import Indexer
    @testable import PeripheryKit
    @testable import ProjectDrivers
    import Shared
    import SystemPackage
    @testable import TestShared
    import XCTest

    /// Scans the union of a macOS and an iOS simulator index store of the same package.
    final class SPMProjectMultiVariantTest: SPMSourceGraphTestCase {
        private static var macOSPlan: IndexPlan!
        /// The plan scanning both stores, nil when the iOS simulator SDK is not installed.
        private static var unionPlan: IndexPlan?
        private static var unionSkipReason = ""
        private static var unionError: Error?

        override static func setUp() {
            super.setUp()

            build(projectPath: SPMProjectMultiVariantPath)
            macOSPlan = plan

            let sdk: String
            do {
                sdk = try shell.exec(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                unionSkipReason = "The iOS simulator SDK is not installed: \(error)"
                return
            }

            SPMProjectMultiVariantPath.chdir {
                do {
                    let iOSStore = try buildIOSSimulatorStore(sdk: sdk)
                    let configuration = Configuration()
                    configuration.indexStorePath = Array(macOSPlan.indexStorePaths) + [iOSStore]
                    let driver = try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
                    unionPlan = try driver.plan(logger: logger.contextualized(with: "index"))
                } catch {
                    unionError = error
                }
            }
        }

        func testSingleStoreAutoMatchesAllClauses() {
            Self.plan = Self.macOSPlan
            let allClauses = scanResults(.allClauses)
            let auto = scanResults(.auto)
            let byDefault = scanResults(nil)

            XCTAssertEqual(auto, allClauses)
            XCTAssertEqual(byDefault, allClauses)
        }

        func testSingleStoreRetainsWhatOtherPlatformsMayUse() {
            Self.plan = Self.macOSPlan
            index(configuration: configuration(.auto))

            // `draw` is written in the iOS clause, which the macOS build did not compile.
            assertReferenced(.struct("Beta")) {
                self.assertReferenced(.functionMethodInstance("draw()"))
            }
            assertReferenced(.module("Util"))
            assertReferenced(.struct("Mode")) {
                self.assertReferenced(.varInstance("debugLabel"))
                self.assertNotReferenced(.varInstance("releaseLabel"))
            }
        }

        func testUnionWithAutoReportsWhatNoBuildUses() throws {
            Self.plan = try unionPlan()
            index(configuration: configuration(.auto))

            assertReferenced(.struct("Beta")) {
                self.assertNotReferenced(.functionMethodInstance("draw()"))
            }
            assertReferenced(.struct("Alpha")) {
                self.assertReferenced(.functionMethodInstance("draw()"))
            }
            assertNotReferenced(.functionFree("phoneNeverCalled()"))
            assertReferenced(.functionFree("phoneCalled()"))
            assertReferenced(.module("Util"))
            assertReferenced(.functionFree("utilOnlyOnPhone()"))
            // Both sides of `@available(iOS, unavailable)` are built, and the nested clause is compiled by the iOS build.
            assertReferenced(.struct("Gamma")) {
                self.assertNotReferenced(.functionMethodInstance("macOnlyNeverCalled()"))
                self.assertReferenced(.functionMethodInstance("macOnlyCalled()"))
            }
            assertReferenced(.struct("Delta")) {
                self.assertReferenced(.functionMethodInstance("paint()"))
            }
            assertReferenced(.struct("Epsilon")) {
                self.assertNotReferenced(.functionMethodInstance("paint()"))
            }
        }

        func testUnionWithAllClausesKeepsUnavailableAndNestedRetention() throws {
            Self.plan = try unionPlan()
            index(configuration: configuration(.allClauses))

            assertReferenced(.struct("Beta")) {
                self.assertNotReferenced(.functionMethodInstance("draw()"))
            }
            assertNotReferenced(.functionFree("phoneNeverCalled()"))
            assertReferenced(.struct("Gamma")) {
                self.assertReferenced(.functionMethodInstance("macOnlyNeverCalled()"))
            }
            assertReferenced(.struct("Epsilon")) {
                self.assertReferenced(.functionMethodInstance("paint()"))
            }
        }

        func testSingleStoreAutoKeepsUnavailableAndNestedRetention() {
            Self.plan = Self.macOSPlan
            index(configuration: configuration(.auto))

            assertReferenced(.struct("Gamma")) {
                self.assertReferenced(.functionMethodInstance("macOnlyNeverCalled()"))
            }
            assertReferenced(.struct("Epsilon")) {
                self.assertReferenced(.functionMethodInstance("paint()"))
            }
        }

        func testUnionWithAutoListsTheVariantsOfEachFile() throws {
            Self.plan = try unionPlan()

            let file = try XCTUnwrap(Self.plan.sourceFiles.keys.first { $0.path.lastComponent?.string == "InBlock.swift" })
            let triples = file.variants.map(\.triple)
            XCTAssertTrue(triples.contains { $0.contains("apple-macos") }, "\(triples)")
            XCTAssertTrue(triples.contains { $0.contains("apple-ios") && $0.hasSuffix("-simulator") }, "\(triples)")
        }

        func testUnionPlanFailsInsteadOfSkippingWhenTheUnionCannotBePlanned() {
            struct PlanFailure: Error {}
            let savedError = Self.unionError
            defer { Self.unionError = savedError }
            Self.unionError = PlanFailure()

            XCTAssertThrowsError(try unionPlan()) { error in
                XCTAssertTrue(error is PlanFailure, "\(error)")
            }
        }

        // MARK: - Private

        private func configuration(_ retention: PlatformConditionalRetention?) -> Configuration {
            let configuration = Configuration()
            if let retention {
                configuration.platformConditionalRetention = retention
            }
            return configuration
        }

        private func scanResults(_ retention: PlatformConditionalRetention?) -> [String] {
            index(configuration: configuration(retention))

            return Self.results.map { "\($0.declaration) \($0.annotation)" }.sorted()
        }

        private func unionPlan() throws -> IndexPlan {
            if let error = Self.unionError {
                throw error
            }
            guard let plan = Self.unionPlan else { throw XCTSkip(Self.unionSkipReason) }

            return plan
        }

        private static func buildIOSSimulatorStore(sdk: String) throws -> FilePath {
            let scratchPath = FilePath(NSTemporaryDirectory()).appending("outskirts-multi-variant-ios").string
            let arguments = ["--scratch-path", scratchPath, "--triple", "arm64-apple-ios18.0-simulator", "--sdk", sdk]
            try shell.exec(["swift", "build"] + arguments)

            return try SPM.Package(configuration: Configuration(), shell: shell, logger: logger)
                .indexStorePath(additionalArguments: arguments)
        }
    }

#endif
