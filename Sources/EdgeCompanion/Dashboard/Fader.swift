import AppKit
import EdgeCore
import SwiftUI

/// A vertical fader: a slot with the level filled in, scale ticks either side and a ridged cap.
/// Drag it up or down, or tap the track to jump there.
struct Fader: View {
  let level: Double
  let muted: Bool
  let enabled: Bool
  /// The fill's colour, telling one channel from another.
  let tint: Color
  let set: (Double) -> Void
  /// Finger travel and the track's length, both in points.
  let drag: (Double, Double) -> Void

  private let capHeight: CGFloat = 34

  var body: some View {
    GeometryReader { geo in
      let travel = max(geo.size.height - capHeight, 1)
      let capY = capHeight / 2 + travel * (1 - level)
      // About 62% of the strip, no narrower than a fingertip (56) unless the strip itself is,
      // and no wider than 84.
      let capW = min(max(geo.size.width * 0.62, 56), 84, geo.size.width)
      let fill = muted ? Theme.textTertiary : tint
      ZStack(alignment: .topLeading) {
        // Scale: a tick every 10%, longer at 0, 50 and 100, where the strip has room beside the cap.
        ForEach(geo.size.width >= capW + 2 * (14 + 2) ? Array(0 ... 10) : [], id: \.self) { i in
          let y = capHeight / 2 + travel * CGFloat(10 - i) / 10
          let major = i % 5 == 0
          let len: CGFloat = major ? 14 : 8
          Group {
            Rectangle().frame(width: len, height: major ? 2 : 1)
              .position(x: geo.size.width / 2 - capW / 2 - len / 2 - 2, y: y)
            Rectangle().frame(width: len, height: major ? 2 : 1)
              .position(x: geo.size.width / 2 + capW / 2 + len / 2 + 2, y: y)
          }
          .foregroundStyle(Color.white.opacity(major ? 0.3 : 0.16))
        }
        // The slot, filled from the bottom up to the cap.
        Capsule().fill(Color.black.opacity(0.55))
          .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
          .frame(width: 10, height: travel + 10)
          .position(x: geo.size.width / 2, y: geo.size.height / 2)
        Capsule().fill(fill)
          .frame(width: 6, height: max(travel * level, 0))
          .position(x: geo.size.width / 2, y: capY + travel * level / 2)
          .shadow(color: muted ? .clear : fill.opacity(0.6), radius: 6)
        cap(width: capW)
          .position(x: geo.size.width / 2, y: capY)
        FaderInput(
          tap: { y in set(MonitorAudio.level(atY: y, top: capHeight / 2, travel: travel)) },
          drag: { dy in drag(dy, travel) })
          .frame(width: geo.size.width, height: geo.size.height)
      }
      .opacity(enabled ? 1 : 0.4)
      .allowsHitTesting(enabled)
    }
    .animation(nil, value: level)
  }

  private func cap(width: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.62), Color(white: 0.74)], startPoint: .top, endPoint: .bottom))
      // Grip ridges and the centre line a desk fader has.
      VStack(spacing: 4) {
        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
        Rectangle().fill(Color.black.opacity(0.85)).frame(height: 3)
        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
        Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
      }
      .padding(.horizontal, 6)
    }
    .frame(width: width, height: capHeight)
    .shadow(color: .black.opacity(0.6), radius: 5, y: 3)
  }
}

/// Touch input for the fader. On the Edge a vertical finger drag arrives as scroll events and a tap
/// as a click, so this view takes both (plus a held mouse drag) instead of a SwiftUI drag gesture.
private struct FaderInput: NSViewRepresentable {
  /// Tap or press at a y position (top-left coordinates).
  let tap: (CGFloat) -> Void
  /// Vertical travel in points; negative is up.
  let drag: (CGFloat) -> Void

  func makeNSView(context: Context) -> InputView { InputView() }

  func updateNSView(_ view: InputView, context: Context) {
    view.tap = tap
    view.drag = drag
  }

  final class InputView: NSView {
    var tap: ((CGFloat) -> Void)?
    var drag: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      tap?(convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
      tap?(convert(event.locationInWindow, from: nil).y)
    }

    override func scrollWheel(with event: NSEvent) {
      // Follow the finger only; momentum after the lift would keep moving the level.
      guard event.momentumPhase.isEmpty else { return }
      let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
      // Scroll deltas are positive when the content (finger) moves down.
      drag?(dy)
    }
  }
}
