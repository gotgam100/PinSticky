import AppKit

struct WindowPlacementManager {
    func defaultFrame() -> CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let size = CGSize(width: 320, height: 260)
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }

    func clampedFrame(_ proposedFrame: CGRect) -> CGRect {
        let visible = bestScreen(for: proposedFrame)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)

        let width = min(max(proposedFrame.width, 220), visible.width)
        let height = min(max(proposedFrame.height, 170), visible.height)
        let x = min(max(proposedFrame.minX, visible.minX), visible.maxX - width)
        let y = min(max(proposedFrame.minY, visible.minY), visible.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    func clampedDotOrigin(_ proposedOrigin: CGPoint) -> CGPoint {
        let dotFrame = CGRect(origin: proposedOrigin, size: CGSize(width: 28, height: 28))
        let visible = bestScreen(for: dotFrame)?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)

        return CGPoint(
            x: min(max(proposedOrigin.x, visible.minX), visible.maxX - 28),
            y: min(max(proposedOrigin.y, visible.minY), visible.maxY - 28)
        )
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        return screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        } ?? NSScreen.main
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
