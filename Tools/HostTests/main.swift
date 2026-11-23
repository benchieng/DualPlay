import Foundation

// Host-runnable assertions for LayoutLogic — no simulator, no Xcode test
// runner: CI compiles this with DualPlay/LayoutLogic.swift under plain
// swiftc and runs the binary. Exits nonzero on any failure.

var failures = 0
func expect(_ cond: Bool, _ what: String) {
    if !cond { failures += 1; print("FAIL: \(what)") }
}

func overlapping(_ a: PaneRect, _ b: PaneRect) -> Bool {
    a.x < b.maxX - 0.001 && b.x < a.maxX - 0.001 && a.y < b.maxY - 0.001 && b.y < a.maxY - 0.001
}

func inside(_ r: PaneRect, _ w: Double, _ h: Double) -> Bool {
    r.x >= -0.001 && r.y >= -0.001 && r.maxX <= w + 0.001 && r.maxY <= h + 0.001
}

// MARK: Axis decisions (geometry only — the size-class trap)

expect(paneAxis(width: 951, height: 430) == .sideBySide, "unfolded landscape -> side by side")
expect(paneAxis(width: 430, height: 951) == .stacked, "unfolded portrait -> stacked")
expect(paneAxis(width: 390, height: 844) == .stacked, "compact iPhone portrait -> stacked")
expect(paneAxis(width: 844, height: 390) == .sideBySide, "compact landscape -> side by side")
expect(paneAxis(width: 500, height: 500) == .stacked, "square -> stacked (documented tie-break)")

// MARK: Stacked layout invariants

for size in [(390.0, 844.0), (430.0, 951.0), (0.0, 100.0), (10.0, 10.0)] {
    let (a, b) = paneRects(width: size.0, height: size.1, spacing: 6)
    expect(a.width == size.0 && b.width == size.0, "stacked panes span full width at \(size)")
    expect(!overlapping(a, b), "stacked panes never overlap at \(size)")
    expect(inside(a, size.0, size.1) && inside(b, size.0, size.1), "stacked panes inside container at \(size)")
    expect(a.height >= 0 && b.height >= 0, "no negative pane at \(size)")
    if size.1 > 12 {
        expect(abs((b.y - a.maxY) - 6) < 0.001, "stacked gap equals spacing at \(size)")
    }
}

// MARK: Side-by-side invariants

for size in [(951.0, 430.0), (844.0, 390.0), (600.0, 100.0), (0.0, 1.0)] {
    let (a, b) = paneRects(width: size.0, height: size.1, spacing: 6)
    expect(!overlapping(a, b), "landscape panes never overlap at \(size)")
    expect(inside(a, size.0, size.1) && inside(b, size.0, size.1), "landscape panes inside container at \(size)")
    expect(a.height == size.1 && b.height == size.1, "landscape panes fill height at \(size)")
    if size.0 > 200 {
        expect(abs(b.x - a.maxX - 6) < 0.001, "landscape gap equals spacing at \(size)")
        expect(abs(a.width - b.width) < 0.001, "no-fold split is symmetric at \(size)")
    }
}

// MARK: Fold strip (book posture) — panes must not straddle the hinge

let containerW = 951.0, containerH = 430.0
let hinge = FoldStrip(centerX: containerW / 2, width: 40)
let (fa, fb) = paneRects(width: containerW, height: containerH, spacing: 6, fold: hinge)
expect(!overlapping(fa, fb), "fold: panes still disjoint")
expect(fa.maxX <= hinge.minX + foldStripPadding + 0.001, "fold: left pane stops at the hinge")
expect(fb.x >= hinge.maxX - foldStripPadding - 0.001, "fold: right pane starts after the hinge")
expect(fa.width > 100 && fb.width > 100, "fold: neither pane starves on a real display")

// Off-center hinge (e.g. app not perfectly centered across screens)
let offHinge = FoldStrip(centerX: containerW * 0.35, width: 40)
let (oa, ob) = paneRects(width: containerW, height: containerH, spacing: 6, fold: offHinge)
expect(oa.maxX <= offHinge.minX + foldStripPadding + 0.001, "off-center fold: left pane respects strip")
expect(ob.x >= offHinge.maxX - foldStripPadding - 0.001, "off-center fold: right pane respects strip")
expect(inside(oa, containerW, containerH) && inside(ob, containerW, containerH), "off-center fold: still inside")

// Hinge against the edge must not push a pane off-screen or invert it
for cx in [10.0, 40.0, containerW - 40.0, containerW - 10.0] {
    let edgeHinge = FoldStrip(centerX: cx, width: 40)
    let (ea, eb) = paneRects(width: containerW, height: containerH, spacing: 6, fold: edgeHinge)
    expect(ea.width >= 0 && eb.width >= 0, "edge fold cx=\(cx): non-negative widths")
    expect(!overlapping(ea, eb), "edge fold cx=\(cx): disjoint")
    expect(inside(ea, containerW, containerH) && inside(eb, containerW, containerH), "edge fold cx=\(cx): inside")
}

// A fold strip wider than the container degenerates gracefully
let fat = paneRects(width: 300, height: 200, spacing: 6, fold: FoldStrip(centerX: 150, width: 320))
expect(fat.0.width >= 0 && fat.1.width >= 0 && !overlapping(fat.0, fat.1), "fat strip: no crash, no overlap")

// Fold never applies to stacked posture (strip is vertical; panes split horizontally)
let (sa, sb) = paneRects(width: 430, height: 951, spacing: 6, fold: FoldStrip(centerX: 215, width: 40))
expect(sa.width == 430 && sb.width == 430, "stacked posture ignores fold strip")

// MARK: Swap is an offset change, not a rebuild (contract used by ContentView)
// paneRects must be deterministic for the same input so animating between
// states is stable.
let d1 = paneRects(width: 951, height: 430, spacing: 6)
let d2 = paneRects(width: 951, height: 430, spacing: 6)
expect(d1 == d2, "paneRects deterministic")

if failures == 0 {
    print("HOST TESTS OK")
    exit(0)
} else {
    print("\(failures) FAILURES")
    exit(1)
}
