import Foundation

// Pure layout decisions for DualPlay — deliberately no UIKit/SwiftUI, so CI
// can compile and assert them on any host (Tools/HostTests/main.swift runs
// under plain swiftc, no simulator). Pattern borrowed from Apollo-Reborn's
// Duo practice: posture/layout logic lives in testable functions, not only
// in view code you can only eyeball.

public enum PaneAxis: String, Equatable {
    case sideBySide   // panes split left/right (landscape container)
    case stacked      // panes split top/bottom (portrait container; squares too)
}

/// Container geometry is the only honest posture signal on the Duo: the
/// inner display reports identical size classes in every orientation, and a
/// side window can fake any aspect ratio — so we read the container, never
/// device orientation or size class.
public func paneAxis(width: Double, height: Double) -> PaneAxis {
    width > height ? .sideBySide : .stacked
}

public struct PaneRect: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// The dead vertical strip UIKit reserves inside the view when the Duo is
/// half-open (book posture). When known, the side-by-side divider is widened
/// and centered on the strip so no video straddles the hinge.
public struct FoldStrip: Equatable {
    public let centerX: Double
    public let width: Double

    public init(centerX: Double, width: Double) {
        self.centerX = centerX
        self.width = max(0, width)
    }

    public var minX: Double { centerX - width / 2 }
    public var maxX: Double { centerX + width / 2 }
}

/// Extra air around the hinge strip so playback controls never crowd it.
public let foldStripPadding: Double = 8

/// Where the divider gap sits: centered by default; on the hinge strip when
/// one is known, clamped so neither pane collapses below `minPaneWidth`.
public func dividerGap(width: Double, minGap: Double, fold: FoldStrip?, minPaneWidth: Double = 120) -> (start: Double, end: Double) {
    var gap = max(0, minGap)
    if let fold { gap = max(gap, fold.width + 2 * foldStripPadding) }
    gap = min(gap, max(0, width))

    let minStart = min(gap / 2, max(0, width / 2 - max(0, minPaneWidth)))
    let maxStart = width - gap - minStart
    let idealStart: Double
    if let fold {
        idealStart = fold.centerX - gap / 2
    } else {
        idealStart = (width - gap) / 2
    }
    let start = min(max(idealStart, minStart), max(minStart, maxStart))
    return (start, start + gap)
}

/// Frames for the two panes inside a container of the given size.
/// Invariants (host-tested): panes never overlap, never leave the container,
/// never go negative, and — when a fold strip is given in side-by-side mode —
/// neither pane straddles the strip.
public func paneRects(width: Double, height: Double, spacing: Double, fold: FoldStrip? = nil) -> (PaneRect, PaneRect) {
    let w = max(0, width)
    let h = max(0, height)
    let s = max(0, spacing)

    switch paneAxis(width: w, height: h) {
    case .stacked:
        let ph = max(0, (h - s) / 2)
        return (PaneRect(x: 0, y: 0, width: w, height: ph),
                PaneRect(x: 0, y: ph + s, width: w, height: ph))
    case .sideBySide:
        let gap = dividerGap(width: w, minGap: s, fold: fold)
        return (PaneRect(x: 0, y: 0, width: gap.start, height: h),
                PaneRect(x: gap.end, y: 0, width: w - gap.end, height: h))
    }
}
