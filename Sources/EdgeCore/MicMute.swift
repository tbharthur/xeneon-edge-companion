import Foundation

/// One audio input device as the mic-mute control sees it.
public struct MicDevice: Equatable, Sendable {
  public var id: UInt32
  public var name: String
  /// CoreAudio transport type four-char code (`usb `, `bltn`, `virt`, `grup`, ...).
  public var transport: UInt32
  public var muteSettable: Bool
  public var muted: Bool
  public var isDefault: Bool
  /// Some app has the mic open (CoreAudio "running somewhere").
  public var inUse: Bool

  public init(id: UInt32, name: String, transport: UInt32, muteSettable: Bool, muted: Bool, isDefault: Bool, inUse: Bool = false) {
    self.id = id
    self.name = name
    self.transport = transport
    self.muteSettable = muteSettable
    self.muted = muted
    self.isDefault = isDefault
    self.inUse = inUse
  }
}

/// Which microphones the mute button controls, and what one tap does.
///
/// It mutes at the device, so every app (Teams, Zoom, Meet, the phone app, the recorder) hears
/// silence, whichever physical mic it picked. Virtual and aggregate devices are left alone:
/// apps such as Teams expose their own virtual input for shared audio, and an aggregate's
/// members are muted directly.
public enum MicMute {
  public static func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  static let skipped: Set<UInt32> = [fourCC("virt"), fourCC("grup"), fourCC("agrp")]

  public static func targets(_ devices: [MicDevice]) -> [MicDevice] {
    devices.filter { $0.muteSettable && !skipped.contains($0.transport) }
  }

  /// Muted only when every controlled mic is muted, so a half-muted state still reads as live.
  public static func isMuted(_ devices: [MicDevice]) -> Bool? {
    let t = targets(devices)
    return t.isEmpty ? nil : t.allSatisfy(\.muted)
  }

  /// A tap mutes everything unless everything is already muted.
  public static func nextMuted(_ devices: [MicDevice]) -> Bool {
    !(isMuted(devices) ?? false)
  }

  /// The mic to name under the button: the one an app has open (Teams often picks a mic other
  /// than the system default), else the default input, else the first.
  public static func label(_ devices: [MicDevice]) -> String? {
    let t = targets(devices)
    let open = t.filter(\.inUse)
    if !open.isEmpty { return open.map(\.name).joined(separator: " + ") }
    return (t.first(where: \.isDefault) ?? t.first)?.name
  }
}
