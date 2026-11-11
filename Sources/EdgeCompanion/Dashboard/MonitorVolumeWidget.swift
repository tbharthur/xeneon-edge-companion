import AppKit
import EdgeCore
import SwiftUI

/// Volume and mute of the desk monitor's own speakers or headphone jack, over DDC/CI (MCCS 0x62 and
/// 0x8D). macOS has no software volume for HDMI/DisplayPort audio, so this is the only way to turn
/// it down without the monitor's buttons. Reads only while the widget is on screen.
@MainActor
final class MonitorVolumeController: ObservableObject {
  static let shared = MonitorVolumeController()

  enum Status: Equatable { case waiting, ready, unavailable }

  /// The monitor's product name ("LG ULTRAWIDE").
  @Published private(set) var name: String?
  /// 0...1.
  @Published private(set) var level: Double?
  /// Nil until the monitor reports it or the widget sets it; treated as unmuted.
  @Published private(set) var muted: Bool?
  @Published private(set) var status: Status = .waiting

  private let ddc = DDCController(display: .monitor)
  private var maximum: UInt16 = 100
  private var users = 0
  private var timer: Timer?
  private var reading = false
  private var writing = false
  private var pendingLevel: Double?
  private var pendingMute: Bool?
  /// The fader's unrounded position while it is being moved.
  private var exact: Double?
  /// Readings are skipped for a moment after a change, so the fader never jumps back mid-drag.
  private var lastChange = Date.distantPast
  private var muteMisses = 0
  private var volumeMisses = 0
  private static let muteMissLimit = 5
  private static let pollSeconds: TimeInterval = 4
  private static let settleSeconds: TimeInterval = 2.5

  func retain() {
    users += 1
    guard users == 1 else { return }
    refresh()
    let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    t.tolerance = 1
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func release() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }

  // MARK: Actions

  func set(_ value: Double) {
    guard status == .ready else { return }
    let v = min(max(value, 0), 1)
    exact = v
    // Whole steps of the monitor's own scale, so the number shown is the one the monitor holds.
    let snapped = Double(MonitorAudio.raw(v, maximum: maximum)) / Double(max(maximum, 1))
    guard snapped != level else { return }
    level = snapped
    pendingLevel = snapped
    lastChange = Date()
    flush()
  }

  /// Moves the fader by a finger's vertical travel. Small moves add up even when each is less
  /// than one step of the monitor's scale.
  func drag(dy: Double, travel: Double) {
    guard status == .ready else { return }
    set(MonitorAudio.dragged(from: exact ?? level ?? 0, dy: dy, travel: travel))
  }

  func toggleMute() {
    guard status == .ready else { return }
    let next = !(muted ?? false)
    muted = next
    pendingMute = next
    lastChange = Date()
    flush()
  }

  /// Sends the newest pending change once the bus is free; changes made meanwhile collapse into one.
  private func flush() {
    guard !writing else { return }
    let mute = pendingMute
    let level = pendingLevel
    guard mute != nil || level != nil else { return }
    pendingMute = nil
    pendingLevel = nil
    writing = true
    let maximum = maximum
    let ddc = ddc
    ddc.queue.async {
      var failed = false
      do {
        if let mute { try ddc.write(.mute, MonitorAudio.muteValue(mute)) }
        if let level { try ddc.write(.volume, MonitorAudio.raw(level, maximum: maximum)) }
      } catch {
        failed = true
        Log.error(.dashboard, "monitor volume: \(error)")
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.writing = false
          self.lastChange = Date()
          if failed { self.lastChange = .distantPast }
          self.flush()
        }
      }
    }
  }

  // MARK: Reading

  private func refresh() {
    guard !reading, !writing, Date().timeIntervalSince(lastChange) > Self.settleSeconds else { return }
    reading = true
    let ddc = ddc
    let askMute = muteMisses < Self.muteMissLimit
    ddc.queue.async {
      var reply: (volume: DDCPacket.VCPReply, muted: Bool?, name: String?)?
      do {
        let volume = try ddc.read(.volume)
        let mute = askMute ? try? ddc.read(.mute) : nil
        reply = (volume, mute.flatMap { MonitorAudio.isMuted($0.current) }, ddc.productName)
      } catch {
        ddc.invalidate()
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.apply(reply) }
      }
    }
  }

  private func apply(_ reply: (volume: DDCPacket.VCPReply, muted: Bool?, name: String?)?) {
    reading = false
    // A change made while the read was in flight wins over what the read saw.
    guard Date().timeIntervalSince(lastChange) > Self.settleSeconds else { return }
    guard let reply else {
      // One missed read is normal on a shared bus; give up only after several in a row.
      volumeMisses += 1
      if volumeMisses >= 3 { status = .unavailable }
      return
    }
    volumeMisses = 0
    maximum = reply.volume.maximum == 0 ? 100 : reply.volume.maximum
    level = MonitorAudio.fraction(current: reply.volume.current, maximum: reply.volume.maximum)
    exact = nil
    // A missed mute read keeps the last known state. A monitor that never reports mute is asked
    // five times, then the widget tracks its own taps.
    if let m = reply.muted {
      muted = m
      muteMisses = 0
    } else if muteMisses < Self.muteMissLimit {
      muteMisses += 1
    }
    name = reply.name
    status = .ready
  }
}

/// A mixing-desk channel strip for the desk monitor: the level on top, a long fader with a scale,
/// and a Mute key that lights red. Drag the fader up or down, or tap the track to jump there.
struct MonitorVolumeWidget: View {
  @ObservedObject private var monitor = MonitorVolumeController.shared

  var body: some View {
    WidgetCard {
      VStack(spacing: 12) {
        header
        if monitor.status == .unavailable {
          unavailable
        } else {
          readout
          Fader(level: monitor.level ?? 0, muted: monitor.muted == true, enabled: monitor.status == .ready,
                set: { monitor.set($0) }, drag: { monitor.drag(dy: $0, travel: $1) })
          muteKey
        }
      }
    }
    .onAppear { monitor.retain() }
    .onDisappear { monitor.release() }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "display").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
      Text(shortName).font(Theme.text(13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        .lineLimit(1).minimumScaleFactor(0.7)
      Spacer(minLength: 0)
    }
  }

  /// "LG ULTRAWIDE" → "LG"; other names as they are.
  private var shortName: String {
    guard let name = monitor.name, !name.isEmpty else { return tr("모니터", "Monitor") }
    if name.uppercased().hasPrefix("LG ") { return "LG" }
    return name
  }

  private var readout: some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(monitor.level.map { "\(Int(($0 * 100).rounded()))" } ?? "–").font(Theme.number(40, weight: .bold))
      if monitor.level != nil { Text("%").font(Theme.number(17, weight: .semibold)).opacity(0.6) }
    }
    .foregroundStyle(monitor.muted == true ? Theme.textTertiary : Theme.textPrimary)
    .strikethrough(monitor.muted == true, color: Theme.critical)
    .lineLimit(1).minimumScaleFactor(0.6)
    .frame(maxWidth: .infinity)
  }

  private var muteKey: some View {
    let on = monitor.muted == true
    return Button { monitor.toggleMute() } label: {
      VStack(spacing: 3) {
        Image(systemName: on ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 18, weight: .semibold))
        Text(on ? tr("음소거됨", "Muted") : tr("음소거", "Mute")).font(Theme.text(13, weight: .bold))
      }
      .foregroundStyle(on ? Color.white : Theme.textPrimary)
      .frame(maxWidth: .infinity)
      .frame(height: 60)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(on ? Theme.critical : Color.white.opacity(0.08))
          .shadow(color: on ? Theme.critical.opacity(0.55) : .clear, radius: 10)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
    .disabled(monitor.status != .ready)
  }

  private var unavailable: some View {
    VStack(spacing: 8) {
      Spacer(minLength: 0)
      Image(systemName: "speaker.slash").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.textTertiary)
      Text(tr("모니터 볼륨을 읽을 수 없어요", "Can't reach the monitor's volume"))
        .font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.center)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }
}

/// A vertical fader: a slot with the level filled in, scale ticks either side and a ridged cap.
private struct Fader: View {
  let level: Double
  let muted: Bool
  let enabled: Bool
  let set: (Double) -> Void
  /// Finger travel and the track's length, both in points.
  let drag: (Double, Double) -> Void

  private let capHeight: CGFloat = 34

  var body: some View {
    GeometryReader { geo in
      let travel = max(geo.size.height - capHeight, 1)
      let capY = capHeight / 2 + travel * (1 - level)
      let capW = min(geo.size.width * 0.62, 84)
      let tint = muted ? Theme.textTertiary : Theme.gpu
      ZStack(alignment: .topLeading) {
        // Scale: a tick every 10%, longer at 0, 50 and 100.
        ForEach(0 ... 10, id: \.self) { i in
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
        Capsule().fill(tint)
          .frame(width: 6, height: max(travel * level, 0))
          .position(x: geo.size.width / 2, y: capY + travel * level / 2)
          .shadow(color: muted ? .clear : tint.opacity(0.6), radius: 6)
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
