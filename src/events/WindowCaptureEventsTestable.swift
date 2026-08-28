import Foundation

enum WindowCaptureEventsTestable {
    /// These WeChat builds set their NSWindow sharing type to `.none`, so per-window capture returns black.
    /// Their tiles deliberately stay on the application icon.
    static func usesAppIconInsteadOfWindowCapture(_ bundleIdentifier: String?) -> Bool {
        return bundleIdentifier == "com.tencent.xinWeChat"
            || bundleIdentifier == "com.tencent.xinWeChat.dual.codex"
    }

    static func screenIndexForCapture(_ windowRect: CGRect, _ screenRects: [CGRect]) -> Int? {
        screenRects.enumerated().compactMap { index, screenRect -> (Int, CGFloat)? in
            let intersection = windowRect.intersection(screenRect)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            return (index, intersection.width * intersection.height)
        }.max { $0.1 < $1.1 }?.0
    }

}
