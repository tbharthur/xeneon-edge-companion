import AppKit
import CoreGraphics
import EdgeCore

/// Moves the Dock to the main display by replaying what a user does: a short push against a free
/// stretch of the main display's Dock edge. Used when the Dock has ended up on the Edge, and when
/// the user pushes down against the fenced bottom of the main display, where most of the edge
/// borders the Edge and macOS itself would not summon the Dock.
///
/// macOS itself puts the Dock on the Edge during the display reconfiguration of most wakes, before
/// the session is even unlocked. While armed, a light watch (about 1 ms a second) moves it back as
/// soon as the session is unlocked, and keeps retrying with backoff if a push does not take.
/// Approach adapted from DockAnchor (MIT, bwya77).
final class DockRelocator {
  private let queue = DispatchQueue(label: "pro.seol.EdgeCompanion.dock", qos: .userInitiated)
  private var pending: DispatchWorkItem?
  private var running = false
  private var lastSummon: TimeInterval = 0

  // Watch state (main thread).
  private var watchedEdge: CGRect?
  private var watchTimer: Timer?
  /// Failed relocation rounds in a row; spaces out further tries so a stuck Dock never turns
  /// into the cursor being yanked every second.
  private var failures = 0
  private var nextTryAt: TimeInterval = 0

  /// Called on the main thread after a relocation, with whether the Dock is now on the main display.
  var onMoved: ((Bool) -> Void)?

  /// Starts (or retargets) the watch that keeps the Dock off `edge`. Main thread.
  func arm(edge: CGRect) {
    watchedEdge = edge
    guard watchTimer == nil else { return }
    let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = 0.2
    RunLoop.main.add(t, forMode: .common)
    watchTimer = t
  }

  /// Stops the watch and any pending check. Main thread.
  func disarm() {
    watchedEdge = nil
    watchTimer?.invalidate()
    watchTimer = nil
    cancel()
  }

  /// Unlock or a display change: look again now instead of waiting for the next tick, and drop
  /// any backoff left from before.
  func nudge(after delay: TimeInterval = 0.3) {
    failures = 0
    nextTryAt = 0
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.tick() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func tick() {
    guard let edge = watchedEdge, !running else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now >= nextTryAt else { return }
    // A push is pointless behind the lock screen; the Dock is hidden there anyway.
    guard !Self.screenIsLocked() else { return }
    guard let dockDisplay = Self.currentDockDisplay() else { return }
    guard dockDisplay.equalTo(edge) else {
      failures = 0
      return
    }
    moveToMain(attempt: 1, reason: failures == 0 ? "the Dock landed on the Edge" : "the Dock is still on the Edge (retry \(failures))") { $0.equalTo(edge) }
  }

  /// True while the login window's lock screen is up.
  static func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
  }

  /// The user is pushing down at the bottom of the main display: bring the Dock if it is elsewhere.
  func summonToMain() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSummon > 3 else { return }
    lastSummon = now
    let main = CGDisplayBounds(CGMainDisplayID())
    moveToMain(attempt: 1, reason: "pushed down at the bottom of the main display") { !$0.equalTo(main) }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  /// The display rect the Dock window currently occupies, if the Dock is visible.
  static func currentDockDisplay() -> CGRect? {
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list where (info[kCGWindowOwnerName as String] as? String) == "Dock" && (info[kCGWindowLayer as String] as? Int) == dockLevel {
      guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
      let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      let centre = CGPoint(x: rect.midX, y: rect.midY)
      return EdgeLocator.allBounds().first { $0.contains(centre) }
    }
    return nil
  }

  /// Moves the Dock to the main display if `shouldMove(dockDisplay)` holds. Main thread.
  private func moveToMain(attempt: Int, reason: String, shouldMove: @escaping (CGRect) -> Bool) {
    guard !running, Permissions.canPostEvents, !Self.screenIsLocked() else { return }
    let main = CGDisplayBounds(CGMainDisplayID())
    guard let dockDisplay = Self.currentDockDisplay(), !dockDisplay.equalTo(main), shouldMove(dockDisplay) else { return }
    // Never fight the user mid-drag.
    guard NSEvent.pressedMouseButtons == 0 else { return }
    let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
    let edge = PointerMath.DockEdge(rawValue: orientation ?? "bottom") ?? .bottom
    guard let trigger = PointerMath.dockTriggerPoint(on: main, edge: edge, displays: EdgeLocator.allBounds()) else {
      Log.info(.pointer, "dock is on another display but the main display has no free \(edge.rawValue) edge")
      nextTryAt = ProcessInfo.processInfo.systemUptime + 30
      return
    }
    running = true
    Log.info(.pointer, "moving the Dock from \(dockDisplay) to the main display via \(trigger): \(reason) (attempt \(attempt))")
    queue.async { [weak self] in
      CursorHider.whileHidden { Self.push(toward: trigger, edge: edge) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard let self else { return }
        self.running = false
        let now = Self.currentDockDisplay()
        if let now, !now.equalTo(main), shouldMove(now), attempt < 2 {
          self.moveToMain(attempt: attempt + 1, reason: reason, shouldMove: shouldMove)
          return
        }
        if let now, !now.equalTo(main), shouldMove(now) {
          self.failures += 1
          let wait = min(60, 5 * pow(2, Double(self.failures - 1)))
          self.nextTryAt = ProcessInfo.processInfo.systemUptime + wait
          Log.info(.pointer, "Dock did not move (\(now)); trying again in \(Int(wait)) s")
          self.onMoved?(false)
        } else {
          self.failures = 0
          Log.info(.pointer, now.map { $0.equalTo(main) ? "Dock is on the main display" : "Dock is on \($0)" } ?? "Dock not visible")
          self.onMoved?(now?.equalTo(main) ?? false)
        }
      }
    }
  }

  /// Approaches the edge, holds against it briefly, then puts the cursor back.
  private static func push(toward edgePoint: CGPoint, edge: PointerMath.DockEdge) {
    let original = CGEvent(source: nil)?.location ?? edgePoint
    PointerGuard.borrow.begin(for: 2)
    defer {
      CGWarpMouseCursorPosition(original)
      CGAssociateMouseAndMouseCursorPosition(1)
      PointerGuard.borrow.end()
    }
    let source = CGEventSource(stateID: .hidSystemState)
    source?.localEventsSuppressionInterval = 0
    source?.userData = EventTag.value
    let approach: CGPoint
    switch edge {
    case .bottom: approach = CGPoint(x: edgePoint.x, y: edgePoint.y - 50)
    case .left: approach = CGPoint(x: edgePoint.x + 50, y: edgePoint.y)
    case .right: approach = CGPoint(x: edgePoint.x - 50, y: edgePoint.y)
    }
    func move(_ p: CGPoint) {
      CGWarpMouseCursorPosition(p)
      guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
      e.setIntegerValueField(.eventSourceUserData, value: EventTag.value)
      e.post(tap: .cghidEventTap)
    }
    move(approach)
    usleep(30000)
    for i in 1 ... 8 {
      let t = CGFloat(i) / 8
      move(CGPoint(x: approach.x + (edgePoint.x - approach.x) * t, y: approach.y + (edgePoint.y - approach.y) * t))
      usleep(15000)
    }
    for _ in 0 ..< 12 {
      move(edgePoint)
      usleep(25000)
    }
  }
}
