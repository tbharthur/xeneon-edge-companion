import CoreGraphics

/// Decides which windows to put back after the Dock leaves the Edge. When macOS parks the Dock on
/// the Edge (usually during wake) it shrinks the windows there to clear it, and they stay small
/// once the Dock is moved off. Frames are global Quartz points (top-left origin), keyed by window
/// number.
public enum WindowRestore {
  /// The saved frame for each window that is still on the Edge but no longer has that frame.
  /// Windows that were closed, moved to another display, or whose saved frame no longer fits on
  /// the Edge are left alone.
  public static func plan(saved: [Int: CGRect], current: [Int: CGRect], edge: CGRect, tolerance: CGFloat = 2) -> [Int: CGRect] {
    var out: [Int: CGRect] = [:]
    for (id, before) in saved {
      guard let now = current[id],
            edge.contains(CGPoint(x: now.midX, y: now.midY)),
            edge.contains(before) else { continue }
      let moved = abs(now.minX - before.minX) > tolerance || abs(now.minY - before.minY) > tolerance
      let resized = abs(now.width - before.width) > tolerance || abs(now.height - before.height) > tolerance
      if moved || resized { out[id] = before }
    }
    return out
  }
}
