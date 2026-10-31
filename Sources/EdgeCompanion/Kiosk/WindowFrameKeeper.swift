import AppKit
import ApplicationServices
import EdgeCore

/// Keeps the Edge's windows at the size they had before the Dock visited.
///
/// While the Dock is elsewhere, it remembers the frame of every window on the Edge. Once the Dock
/// lands on the Edge (macOS shrinks those windows to clear it) the memory is frozen, and after the
/// Dock relocator has moved the Dock off again, each window that changed is put back.
final class WindowFrameKeeper {
  private struct Saved {
    let pid: pid_t
    let owner: String
    let frame: CGRect
  }

  private var edgeBounds: CGRect?
  private var saved: [Int: Saved] = [:]
  /// Set from the moment the Dock is seen on the Edge (or about to be moved off it) until the
  /// windows are restored, so shrunken frames never overwrite the good ones.
  private var frozen = false
  private var timer: Timer?
  private var pendingRestore: DispatchWorkItem?
  private let ownPID = ProcessInfo.processInfo.processIdentifier

  /// Active while the Dock lock is on and the Edge is present. Main thread.
  func configure(edgeBounds: CGRect?, enabled: Bool) {
    guard enabled, let edgeBounds else {
      self.edgeBounds = nil
      timer?.invalidate()
      timer = nil
      saved.removeAll()
      frozen = false
      return
    }
    if self.edgeBounds != edgeBounds {
      saved.removeAll()
      frozen = false
    }
    self.edgeBounds = edgeBounds
    guard timer == nil else { return }
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = 0.5
    RunLoop.main.add(t, forMode: .common)
    timer = t
    tick()
  }

  /// The relocator is about to push the Dock off the Edge: stop remembering.
  func dockWillMove() {
    frozen = true
  }

  /// The relocator finished; restore once the Dock's departure has settled.
  func dockMoved(toMain: Bool) {
    guard toMain else { return }
    pendingRestore?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.restore() }
    pendingRestore = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private static var screenLocked: Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  private func tick() {
    guard let edge = edgeBounds, !Self.screenLocked else { return }
    let dock = DockRelocator.currentDockDisplay()
    if dock?.equalTo(edge) == true {
      frozen = true
      return
    }
    // The Dock left the Edge some other way (e.g. the user pushed it off): restore now.
    if frozen {
      restore()
      return
    }
    // Hidden Dock (nil) is fine to record through: it reserves no space.
    saved = Self.windowsOnEdge(edge, ownPID: ownPID)
  }

  private func restore() {
    pendingRestore?.cancel()
    pendingRestore = nil
    defer { frozen = false }
    guard let edge = edgeBounds, !Self.screenLocked else { return }
    let current = Self.windowsOnEdge(edge, ownPID: ownPID)
    let plan = WindowRestore.plan(saved: saved.mapValues(\.frame), current: current.mapValues(\.frame), edge: edge)
    for (id, target) in plan {
      guard let now = current[id], let before = saved[id] else { continue }
      if AXWindows.setFrame(pid: before.pid, matching: now.frame, to: target) {
        Log.info(.evictor, "restored a \(before.owner) window to its size before the Dock visited the Edge")
      } else {
        Log.error(.evictor, "could not restore a \(before.owner) window (\(now.frame) → \(target))")
      }
    }
    saved = Self.windowsOnEdge(edge, ownPID: ownPID)
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
