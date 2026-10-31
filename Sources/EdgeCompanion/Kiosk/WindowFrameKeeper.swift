import AppKit
import ApplicationServices
import EdgeCore

/// Keeps the Edge's windows at the size they had before the Dock visited.
///
/// macOS parks the Dock on the Edge during most wakes and shrinks the windows there to clear it.
/// This remembers the Edge's window frames once, as the screens lock or sleep (window positions
/// stay readable while locked), and after the Dock relocator has moved the Dock off the Edge it
/// puts back each window that changed. Frames are kept in memory only, and are dropped once a
/// wake has settled so they can never undo a later change.
final class WindowFrameKeeper {
  private struct Saved {
    let pid: pid_t
    let owner: String
    let frame: CGRect
  }

  private var edgeBounds: CGRect?
  private var saved: [Int: Saved] = [:]
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var pendingRestore: DispatchWorkItem?
  private var pendingDiscard: DispatchWorkItem?
  private let ownPID = ProcessInfo.processInfo.processIdentifier

  /// Active while the Dock lock is on and the Edge is present. Main thread.
  func configure(edgeBounds: CGRect?, enabled: Bool) {
    guard enabled, let edgeBounds else {
      self.edgeBounds = nil
      saved.removeAll()
      observers.forEach { $0.0.removeObserver($0.1) }
      observers.removeAll()
      return
    }
    if self.edgeBounds != edgeBounds { saved.removeAll() }
    self.edgeBounds = edgeBounds
    guard observers.isEmpty else { return }
    let ws = NSWorkspace.shared.notificationCenter
    let dnc = DistributedNotificationCenter.default()
    func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (WindowFrameKeeper) -> Void) {
      observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        if let self { action(self) }
      }))
    }
    // Going down: remember. Lock usually comes first (on display dim), then screen and system sleep.
    on(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.remember() }
    on(ws, NSWorkspace.screensDidSleepNotification) { $0.remember() }
    on(ws, NSWorkspace.willSleepNotification) { $0.remember() }
    // Coming back: once usable, give the relocator time to move the Dock, then forget.
    on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.discardLater() }
    on(ws, NSWorkspace.screensDidWakeNotification) { if !Self.screenLocked { $0.discardLater() } }
  }

  /// The relocator moved the Dock off the Edge; restore once its departure has settled.
  func dockMoved(toMain: Bool) {
    guard toMain, !saved.isEmpty else { return }
    let frames = saved
    saved.removeAll()
    pendingRestore?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.restore(frames) }
    pendingRestore = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private static var screenLocked: Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  private func remember() {
    guard let edge = edgeBounds else { return }
    pendingDiscard?.cancel()
    // Already on the Edge: these frames may be the shrunken ones; keep what we had.
    if DockRelocator.currentDockDisplay()?.equalTo(edge) == true { return }
    saved = Self.windowsOnEdge(edge, ownPID: ownPID)
  }

  private func discardLater() {
    pendingDiscard?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saved.removeAll() }
    pendingDiscard = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
  }

  private func restore(_ frames: [Int: Saved]) {
    guard let edge = edgeBounds, !Self.screenLocked else { return }
    let current = Self.windowsOnEdge(edge, ownPID: ownPID)
    let plan = WindowRestore.plan(saved: frames.mapValues(\.frame), current: current.mapValues(\.frame), edge: edge)
    for (id, target) in plan {
      guard let now = current[id], let before = frames[id] else { continue }
      if AXWindows.setFrame(pid: before.pid, matching: now.frame, to: target) {
        Log.info(.evictor, "restored a \(before.owner) window to its size before the Dock visited the Edge")
      } else {
        Log.error(.evictor, "could not restore a \(before.owner) window (\(now.frame) → \(target))")
      }
    }
  }

  /// Normal app windows whose centre is on the Edge, by window number.
  private static func windowsOnEdge(_ edge: CGRect, ownPID: pid_t) -> [Int: Saved] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
    var out: [Int: Saved] = [:]
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
            let id = info[kCGWindowNumber as String] as? Int,
            let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
            let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
      let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      guard rect.width > 40, rect.height > 40, edge.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
      out[id] = Saved(pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "?", frame: rect)
    }
    return out
  }
}

/// Accessibility helpers for other apps' windows, located by their current frame.
enum AXWindows {
  static func frame(_ w: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posRef, let sizeRef else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
  }

  /// Sets the frame of `pid`'s window currently at `current`. False if no such window was found.
  @discardableResult
  static func setFrame(pid: pid_t, matching current: CGRect, to target: CGRect) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return false }
    for w in windows {
      guard let f = frame(w), abs(f.minX - current.minX) < 2, abs(f.minY - current.minY) < 2 else { continue }
      var origin = target.origin
      var size = target.size
      // Position, size, position: some apps refuse a size that would not fit at the old position.
      if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
      if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
      if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
      return true
    }
    return false
  }
}
