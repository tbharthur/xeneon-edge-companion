import EdgeCore
import Foundation

/// Volume and mute of the desk monitor's own speakers or headphone jack, over DDC/CI (MCCS 0x62 and
/// 0x8D). macOS has no software volume for HDMI/DisplayPort audio, so this is the only way to turn
/// it down without the monitor's buttons. Reads only while a card showing it is on screen.
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
