import ColorSync
import CoreGraphics
import Darwin
import EdgeCore
import Foundation
import IOKit

/// Darkens and restores the screens: zero gamma on every display (instant, and invisible to screen
/// capture, so Computer Use keeps working) plus DDC brightness 0 on external monitors that speak
/// DDC, the Edge included. Gamma calls are cheap; DDC runs on each display's own controller queue.
enum DisplayDarkener {
  struct Screen {
    let id: CGDirectDisplayID
    let uuid: String
    let isAsleep: Bool
    /// The framebuffer path tying this display to its DDC service; nil for built-in panels or
    /// when CoreDisplay can't say.
    let location: String?
  }

  static func screens() -> [Screen] {
    EdgeLocator.onlineDisplays().compactMap { id in
      guard let uuid = EdgeLocator.uuidString(id) else { return nil }
      return Screen(id: id, uuid: uuid, isAsleep: CGDisplayIsAsleep(id) != 0,
                    location: CGDisplayIsBuiltin(id) != 0 ? nil : displayLocation(id))
    }
  }

  /// Framebuffer paths that have an external DDC service. Walks the IORegistry, so it is called on
  /// a blank request or a display change, never on a timer.
  static func ddcLocations() -> Set<String> {
    let framebuffers = IORegistryDisplays.framebuffers { _ in true }
    defer { framebuffers.forEach { IOObjectRelease($0.avServiceEntry) } }
    return Set(framebuffers.map(\.location).filter { !$0.isEmpty })
  }

  // MARK: Gamma

  static func zeroGamma() {
    var zero: [CGGammaValue] = [0, 0]
    for id in EdgeLocator.onlineDisplays() {
      CGSetDisplayTransferByTable(id, 2, &zero, &zero, &zero)
    }
  }

  /// False when something (a wake, a reconnect, ColorSync) put a display's gamma back.
  static func gammaIsDark(_ id: CGDirectDisplayID) -> Bool {
    var red = [CGGammaValue](repeating: 1, count: 256)
    var green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return true }
    let n = Int(count)
    return max(red[n - 1], green[n - 1], blue[n - 1]) < 0.02
  }

  static func restoreGamma() {
    CGDisplayRestoreColorSyncSettings()
  }

  // MARK: DDC (call on the controller's queue)

  /// Brightness reading on the display's own scale, or nil when the shared bus gave no clean reply.
  static func readBrightness(_ ddc: DDCController) -> Int? {
    (try? ddc.readBrightness()).map { Int($0.current) }
  }

  /// Writes and confirms by reading back; a garbled readback (the bus is shared with MonitorControl
  /// and the volume strip) trusts the write. At most three rounds, so it never drags on.
  static func setBrightness(_ ddc: DDCController, _ value: Int) -> Bool {
    var wrote = false
    for _ in 0 ..< 3 {
      do {
        try ddc.writeBrightness(UInt16(clamping: value))
        wrote = true
      } catch {
        continue
      }
      guard let read = readBrightness(ddc) else { return true }
      if read == value { return true }
    }
    return wrote
  }

  // MARK: CoreDisplay

  private typealias InfoFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

  /// `CoreDisplay_DisplayCreateInfoDictionary`, as MonitorControl and m1ddc use to match a display
  /// to its framebuffer. Looked up at run time; without it monitors are dimmed by gamma only.
  private static let createInfo: InfoFunction? = {
    let symbol = "CoreDisplay_DisplayCreateInfoDictionary"
    if let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) { return unsafeBitCast(s, to: InfoFunction.self) }
    guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
          let s = dlsym(handle, symbol) else { return nil }
    return unsafeBitCast(s, to: InfoFunction.self)
  }()

  static func displayLocation(_ id: CGDirectDisplayID) -> String? {
    guard let createInfo, let info = createInfo(id)?.takeRetainedValue() as? [String: Any] else { return nil }
    return info["IODisplayLocation"] as? String
  }
}
