#if os(macOS)
    @testable import TestShared
    import XCTest

    final class SwiftUIWidgetRetentionTest: FixtureSourceGraphTestCase {
        func testRetainsTextFieldStyleBody() {
            analyze(retainPublic: true) {
                assertReferenced(.struct("TextFieldStyleFixture")) {
                    self.assertReferenced(.functionMethodInstance("_body(configuration:)"))
                    self.assertNotReferenced(.functionMethodInstance("unusedHelper()"))
                }
                assertReferenced(.struct("ExtensionTextFieldStyleFixture")) {
                    self.assertReferenced(.functionMethodInstance("_body(configuration:)"))
                }
                assertNotReferenced(.struct("UnusedTextFieldStyleFixture"))
                assertNotReferenced(.struct("NonStyleFixture"))
            }
        }

        func testRetainsShapeStyleApply() {
            analyze(retainPublic: true) {
                assertReferenced(.struct("ShapeStyleFixture")) {
                    self.assertReferenced(.functionMethodInstance("_apply(to:)"))
                    self.assertNotReferenced(.functionMethodInstance("unusedHelper()"))
                }
                assertNotReferenced(.struct("UnusedShapeStyleFixture"))
            }
        }

        func testRetainsWidgetPreviewHelpers() {
            analyze(retainPublic: true) {
                assertReferenced(.struct("PreviewedWidgetEntry")) {
                    self.assertReferenced(.varStatic("previewOnlySample"))
                    self.assertNotReferenced(.varStatic("unreferencedSample"))
                    self.assertNotReferenced(.varStatic("deadPreviewSample"))
                }
                assertNotReferenced(.struct("DeadPreviewedWidget"))
            }
        }

        func testRetainsAppKitPreviewHelpers() {
            analyze(retainPublic: true) {
                assertReferenced(.class("PreviewedViewController")) {
                    self.assertReferenced(.varStatic("previewOnlyTitle"))
                    self.assertNotReferenced(.varStatic("unreferencedTitle"))
                }
                assertReferenced(.class("PreviewedSubViewController")) {
                    self.assertReferenced(.varStatic("previewOnlyTitle"))
                }
                assertReferenced(.class("PreviewedView")) {
                    self.assertReferenced(.varStatic("previewOnlyFrame"))
                }
                assertNotReferenced(.class("DeadPreviewedView"))
            }
        }

        func testRetainsPreviewProviderOfUsedView() {
            analyze(retainPublic: true) {
                assertReferenced(.struct("UsedProvidedPreviewView_Previews"))
                assertReferenced(.enum("ProvidedPreviewSampleData")) {
                    self.assertReferenced(.varStatic("title"))
                    self.assertNotReferenced(.varStatic("unreferencedTitle"))
                }
                assertNotReferenced(.struct("DeadProvidedPreviewView"))
                assertNotReferenced(.struct("DeadProvidedPreviewView_Previews"))
                assertNotReferenced(.enum("DeadProvidedPreviewSampleData"))
            }
        }
    }
#endif
