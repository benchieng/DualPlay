import SwiftUI
import UIKit

// iPhone Duo book-posture detection, per Apollo-Reborn's field mechanics:
// the dead strip between the two screens of a half-open device is a
// *reserved division region* on the UIWindow — stock iOS 27.1 API
// (-[UIWindow reservedRegionsOfKind:] with UIViewReservedRegionKind
// .divisionRegionKind). We invoke it name-based through the Obj-C runtime:
// the Swift import spelling isn't guaranteed across SDK builds, and
// name-based calls degrade to "no strip" on non-Duo devices and older iOS,
// where the app simply keeps its old centered divider.
//
// Wake: UIKit sends NO notification when the region changes, and it can
// publish ~1.5 s AFTER the physical hinge moves (Apollo's measurement;
// Apollo wakes on UIHingeInteraction, then polls 4 s). A few KVC reads every
// 300 ms is too cheap to defend a battery budget against here, so we poll
// continuously and publish only actual changes — same "posture is read from
// the region, never inferred from hinge angle" rule Apollo states.

final class PostureUIView: UIView {
    var onChange: ((FoldStrip?) -> Void)?
    private var timer: Timer?
    private var lastFrame: CGRect?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let next = Self.divisionFrame(in: self)
        guard next != lastFrame else { return }
        lastFrame = next
        // Book posture gives a *vertical* strip (taller than wide); a
        // horizontal division belongs to a different posture our stacked
        // layout is indifferent to.
        if let f = next, f.height >= f.width, f.width > 0 {
            onChange?(FoldStrip(centerX: Double(f.midX), width: Double(f.width)))
        } else {
            onChange?(nil)
        }
    }

    /// Active division region, converted into `view`'s coordinate space.
    static func divisionFrame(in view: UIView) -> CGRect? {
        guard let window = view.window,
              let kindClass = NSClassFromString("UIViewReservedRegionKind")
        else { return nil }
        let kindObj = kindClass as AnyObject
        let kindSel = NSSelectorFromString("divisionRegionKind")
        guard kindObj.responds(to: kindSel),
              let kind = kindObj.perform(kindSel)?.takeUnretainedValue()
        else { return nil }
        let regionsSel = NSSelectorFromString("reservedRegionsOfKind:")
        guard window.responds(to: regionsSel),
              let regions = window.perform(regionsSel, with: kind)?
                .takeUnretainedValue() as? [AnyObject]
        else { return nil }
        for region in regions {
            let active = (region.value(forKey: "isActive") as? Bool)
                ?? (region.value(forKey: "active") as? Bool) ?? false
            guard active else { continue }
            guard let frame = (region.value(forKey: "frame") as? NSValue)?.cgRectValue,
                  !frame.isNull,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0
            else { continue }
            return view.convert(frame, from: window)   // window coords -> ours
        }
        return nil
    }
}

/// Reports the book-posture division strip (in its own coordinate space)
/// whenever it appears, moves, or disappears.
struct PostureProbe: UIViewRepresentable {
    var onChange: (FoldStrip?) -> Void

    func makeUIView(context: Context) -> PostureUIView {
        let view = PostureUIView()
        view.isHidden = true          // invisible; timers run fine hidden
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: PostureUIView, context: Context) {
        uiView.onChange = onChange
    }
}
