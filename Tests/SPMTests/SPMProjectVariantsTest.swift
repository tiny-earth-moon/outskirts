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

    /// Builds the macOS + iOS package with the `variants` setting, which runs one build per variant.
    final class SPMProjectVariantsTest: SPMSourceGraphTestCase {
        private struct Scan {
            let configuration: Configuration
            let plan: IndexPlan
            let builtVariants: [String]
        }

        private static let macOSTriple = "arm64-apple-macosx15.0"
        private static let iOSTriple = "arm64-apple-ios18.0-simulator"
        private static var scans: [String: Result<Scan, Error>] = [:]

        func testAutoBuildsEveryPlatformAndReportsWhatNoBuildUses() throws {
            try skipUnlessIOSSimulatorSDKIsInstalled()
            let scan = try scan(.auto)

            XCTAssertEqual(scan.builtVariants.count, 2, "\(scan.builtVariants)")
            XCTAssertTrue(scan.builtVariants.contains { $0.contains("-apple-macosx") }, "\(scan.builtVariants)")
            XCTAssertTrue(scan.builtVariants.contains { $0.contains("-apple-ios") && $0.hasSuffix("-simulator") }, "\(scan.builtVariants)")
            XCTAssertEqual(scan.plan.indexStorePaths.count, 2)
            XCTAssertEqual(scan.configuration.resolvedPlatformConditionalRetention, .auto)

            assertReportsWhatNoBuildUses()
        }

        func testExplicitListBuildsTheGivenVariants() throws {
            try skipUnlessIOSSimulatorSDKIsInstalled()
            let scan = try scan(.explicit([
                BuildVariant(triple: Self.macOSTriple),
                BuildVariant(triple: Self.iOSTriple, sdk: "iphonesimulator", configuration: "debug"),
            ]))

            XCTAssertEqual(scan.builtVariants, [Self.macOSTriple, "\(Self.iOSTriple),sdk=iphonesimulator,configuration=debug"])
            assertReportsWhatNoBuildUses()
        }

        func testVariantWithAMissingSDKIsSkipped() throws {
            let scan = try scan(.explicit([
                BuildVariant(triple: Self.macOSTriple),
                BuildVariant(triple: Self.iOSTriple, sdk: "nosuchsdk"),
            ]))

            XCTAssertEqual(scan.builtVariants, [Self.macOSTriple])
            XCTAssertEqual(scan.plan.indexStorePaths.count, 1)
            // Only the macOS build is indexed, so the name written in the iOS clause stays retained.
            assertReferenced(.struct("Beta")) {
                self.assertReferenced(.functionMethodInstance("draw()"))
            }
        }

        func testDefaultIsTheSingleBuildOfThePackage() throws {
            let scan = try scan(.default)

            XCTAssertEqual(scan.builtVariants, [])
            XCTAssertEqual(scan.plan.indexStorePaths.count, 1)
            XCTAssertTrue(scan.plan.indexStorePaths.allSatisfy { $0.string.contains("/.build/") }, "\(scan.plan.indexStorePaths)")
            XCTAssertEqual(scan.configuration.resolvedPlatformConditionalRetention, .allClauses)
            assertReferenced(.struct("Beta")) {
                self.assertReferenced(.functionMethodInstance("draw()"))
            }
        }

        func testSkippedBuildReportsNoBuiltVariant() throws {
            let configuration = Configuration()
            configuration.variants = .explicit([BuildVariant(triple: Self.macOSTriple)])

            try SPMProjectMultiVariantPath.chdir {
                let driver = try SPMProjectDriver(configuration: configuration, shell: Self.shell, logger: Self.logger)
                try driver.build()
                XCTAssertEqual(driver.builtVariants, [Self.macOSTriple])

                // The index store of the earlier build is read, but nothing proves it matches the sources.
                configuration.skipBuild = true
                let skipping = try SPMProjectDriver(configuration: configuration, shell: Self.shell, logger: Self.logger)
                try skipping.build()
                _ = try skipping.plan(logger: Self.logger.contextualized(with: "index"))
                XCTAssertEqual(skipping.builtVariants, [])
            }
        }

        // MARK: - Private

        private func assertReportsWhatNoBuildUses() {
            assertReferenced(.struct("Beta")) {
                self.assertNotReferenced(.functionMethodInstance("draw()"))
            }
            assertNotReferenced(.functionFree("phoneNeverCalled()"))
            assertReferenced(.functionFree("phoneCalled()"))
            // `import Util` is used by the iOS build only: the module is referenced, the import is not reported.
            assertReferenced(.module("Util"))
        }

        /// Builds and plans the fixture once per value, then indexes it with the same configuration.
        private func scan(_ variants: BuildVariants) throws -> Scan {
            let key = variants.description
            if Self.scans[key] == nil {
                Self.scans[key] = Result { try Self.buildAndPlan(variants) }
            }

            let scan = try XCTUnwrap(Self.scans[key]).get()
            Self.plan = scan.plan
            index(configuration: scan.configuration)
            return scan
        }

        private static func buildAndPlan(_ variants: BuildVariants) throws -> Scan {
            let configuration = Configuration()
            configuration.variants = variants
            // Only evict the caches of projects that are gone, never the user's other caches.
            configuration.cacheMaxAgeDays = 0
            configuration.cacheMaxSizeGB = 0

            var scan: Scan?
            try SPMProjectMultiVariantPath.chdir {
                let driver = try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
                try driver.build()
                let plan = try driver.plan(logger: logger.contextualized(with: "index"))
                scan = Scan(configuration: configuration, plan: plan, builtVariants: driver.builtVariants)
            }
            return try XCTUnwrap(scan)
        }

        private func skipUnlessIOSSimulatorSDKIsInstalled() throws {
            do {
                try Self.shell.exec(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
            } catch {
                throw XCTSkip("The iOS simulator SDK is not installed: \(error)")
            }
        }
    }

#endif
