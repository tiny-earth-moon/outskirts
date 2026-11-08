import AppKit
import SwiftUI

final class PreviewedViewController: NSViewController {}

final class PreviewedSubViewController: PreviewedBaseViewController {}

class PreviewedBaseViewController: NSViewController {}

final class PreviewedView: NSView {}

public enum AppKitPreviewHost {
    public static func make() -> [AnyObject] {
        [PreviewedViewController(), PreviewedSubViewController(), PreviewedView()]
    }
}

extension PreviewedViewController {
    static let previewOnlyTitle = "Preview"
    static let unreferencedTitle = "Unused"
}

extension PreviewedSubViewController {
    static let previewOnlyTitle = "Preview"
}

extension PreviewedView {
    static let previewOnlyFrame = NSRect.zero
}

@available(macOS 14.0, *)
#Preview {
    let controller = PreviewedViewController()
    controller.title = PreviewedViewController.previewOnlyTitle
    return controller
}

@available(macOS 14.0, *)
#Preview {
    let controller = PreviewedSubViewController()
    controller.title = PreviewedSubViewController.previewOnlyTitle
    return controller
}

@available(macOS 14.0, *)
#Preview {
    PreviewedView(frame: PreviewedView.previewOnlyFrame)
}

final class DeadPreviewedView: NSView {
    static let deadPreviewFrame = NSRect.zero
}

@available(macOS 14.0, *)
#Preview {
    DeadPreviewedView(frame: DeadPreviewedView.deadPreviewFrame)
}
